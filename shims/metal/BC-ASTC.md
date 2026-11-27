# BC to ASTC 4×4 proof of concept

The original experiment ran in the host tests. The Metal allocator has to pick
a format before it sees the first upload. BC1 RGBA descriptors give no
opacity guarantee, and choosing ASTC after seeing only the first upload would
miss punch-through blocks in later mips or partial updates. The direct
punch-through mode preserves alpha but changes transparent black, which can
affect unpremultiplied sampling and bilinear filtering. The original experiment
proposed testing BC1 with an external opacity guarantee. The runtime
pilot and its risk decision are described in [T009-I](#t009-i-bc1-direto-no-runtime).

## Block budget and measurements

[ASTC specification, Khronos Data Format 1.4](https://registry.khronos.org/DataFormat/specs/1.4/dataformat.1.4.pdf)

- BC1 four-color blocks use one partition, RGB direct (CEM 8), and 32 bits
  of weights (0, 21, 43, 64). The 17-bit header leaves 79 endpoint bits,
  enough for six 8-bit components. Three-color blocks without any transparent
  index instead use the 0, 32, 64 weight grid with 26 bits.
- BC1 punch-through uses RGBA direct (CEM 12) and two planes with 32
  three-level weights in 52 bits. The 17-bit header and two-bit plane
  selector leave 57 bits, enough for eight seven-bit endpoints. Alpha uses
  only the extremes. Arbitrary masks need the independent alpha plane.
  Transparent RGB can only be chosen along the opaque RGB endpoints in this
  mode, and the PoC chooses the darker endpoint.
- BC2's 16 independent alpha steps and BC3's eight indices would require
  four and three bits per texel respectively for an unrestricted alpha
  grid. With two RGB weight bits, separate grids would use 96 and 80 bits
  for weights. ASTC uses the same weight range on both planes. For BC2 that
  would require 128 bits for weights alone. BC3 would require 96, leaving
  13 endpoint bits after the header and selector, below CEM 12's minimum
  of 21. BC3's six-step mode also has explicit 0 and 255 entries outside
  its interpolated endpoint ramp. Fewer weights, smaller grids, or heuristic
  partitions can approximate these formats. The measured generic encoder
  results favor keeping RGBA8 for arbitrary blocks in this experiment.

Results on a Ryzen 5 4600G, one thread, GCC -O3, seeded synthetic 1024×1024
images with random blocks and forced BC1 modes. PSNR is in dB on byte
values before the sRGB transfer, followed by maximum byte error. Generic
times include BC decode and exclude ASTC context construction. Arm astcenc
5.3.0 verified every direct block and independently decoded both profiles.

| Input | Codec | ms | MPix/s | RGB | Alpha |
| --- | --- | ---: | ---: | ---: | ---: |
| BC1 opaque | Direct linear | 0.89 | 1182.77 | 58.64 / 1 | ∞ / 0 |
| BC1 opaque | Direct sRGB | 0.89 | 1182.77 | ∞ / 0 | ∞ / 0 |
| BC1 opaque | astcenc fastest | 68.16 | 15.38 | 58.38 / 3 | ∞ / 0 |
| BC1 opaque | astcenc fast | 72.90 | 14.38 | 58.40 / 3 | ∞ / 0 |
| BC1 punch-through | Direct linear | 8.63 | 121.46 | 11.45 / 255 | ∞ / 0 |
| BC1 punch-through | Direct sRGB | 8.63 | 121.46 | 11.45 / 255 | ∞ / 0 |
| BC1 punch-through | astcenc fastest | 853.15 | 1.23 | 24.88 / 222 | 30.60 / 235 |
| BC1 punch-through | astcenc fast | 1548.45 | 0.68 | 28.44 / 203 | 36.36 / 206 |
| BC2 | astcenc fastest | 921.96 | 1.14 | 31.59 / 78 | 25.41 / 131 |
| BC2 | astcenc fast | 1877.06 | 0.56 | 31.19 / 166 | 24.77 / 167 |
| BC3 | astcenc fastest | 837.57 | 1.25 | 32.35 / 144 | 27.77 / 165 |
| BC3 | astcenc fast | 1587.36 | 0.66 | 32.57 / 119 | 25.95 / 210 |

For direct punch-through, visible RGB measures 51.42 dB linear and 51.51 dB
sRGB, both max error 1. The direct rectangle path uses no heap or intermediate
RGBA. GCC reports 112 B for the rectangle frame and 96 B for its block callee.
The packed output is 1 MiB for 1024×1024. The generic full-image path needs
a 4 MiB decoded input at that size plus codec workspace; decoding and
encoding smaller tiles could lower that requirement. The offline sanitizer
suite checks mip chains, block-aligned subregions, padded pitches, and
partial edge blocks.

To reproduce the optional independent test and benchmark from the repo root
on x86-64 with AVX2, use a temporary directory:

```sh
bench=$(mktemp -d)
curl -fL https://codeload.github.com/ARM-software/astc-encoder/tar.gz/refs/tags/5.3.0 -o "$bench/arm.tar.gz"
tar -xzf "$bench/arm.tar.gz" -C "$bench"
arm="$bench/astc-encoder-5.3.0"
cmake -S "$arm" -B "$bench/build" -DASTCENC_ISA_AVX2=ON -DCMAKE_BUILD_TYPE=Release
cmake --build "$bench/build" -j
for module in spbcdecode spbclayout spbcastc; do
    cc -O3 -std=c11 -fstack-usage -Ishims/metal -c "shims/metal/$module.c" -o "$bench/$module.o"
done
c++ -O3 -std=c++17 -Ishims/metal -I"$arm/Source" shims/metal/tests/bench_bc_astc.cpp \
    "$bench"/spbc*.o "$bench/build/Source/libastcenc-avx2-static.a" -pthread -o "$bench/bench"
"$bench/bench"
```

## Metal integration constraints

- [Descriptor and heap sizing](spbcfallback.m#L629) must agree on the
  physical format before allocation. The current fallback substitutes the
  decoded format. ASTC would require changing both and using ASTC only for
  supported types and usages.
- [Views](spbcfallback.m#L453) currently translate same-kind variants into
  physical RGBA views. ASTC 4×4 sRGB and linear forms can share bits within
  their own format family. BC and ASTC are different view classes, as are
  RGBA8 and ASTC. [Metal format compatibility](https://developer.apple.com/documentation/metal/mtltexture/maketextureview%28pixelformat%3A%29)
- [GPU copies](spbcfallback.m#L1031) compare decoded formats today. Compare
  actual physical formats for an ASTC path and explicitly reject mixed
  layouts. [Readbacks](spbcfallback.m#L425) already reject BC readback
  through the shim. ASTC bytes returned by native readback could not stand
  in for BC, and RGBA readback would require a conversion.
- Upload existing mips with byte pitches per row of 4×4 blocks, including a
  whole block at partial edges. The same ASTC bitstream supports linear and
  sRGB sampling. The current [GPU mip generation](spbcfallback.m#L1098)
  forwards to Metal and would need an explicit policy for ASTC because it
  requires a color-renderable format. [Compressed updates](https://developer.apple.com/documentation/metal/mtltexture/replace%28region%3Amipmaplevel%3Awithbytes%3Abytesperrow%3A%29) · [Mip generation](https://developer.apple.com/documentation/metal/mtlblitcommandencoder/generatemipmaps%28for%3A%29) · [Feature tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf)
- Skip a persistent per-block cache for this PoC. Hash, lookup, disk, and
  index overhead could cost more than the direct conversion. If repeated
  generic encoding justifies a cache, key by source BC format and block
  bytes or a verified hash, destination block format, and codec version and
  options. Discard old entries when any of those decoding or encoding
  semantics change.
- The launcher loads the game in-process with `dlopen`
  ([launcher.m](../../apps/client/launcher.m#L885)). For a future shim
  that recognizes the flag, `DEVICECTL_CHILD_SP_BC_ASTC=1 apps/client/run.sh`
  uses the existing debug launch mechanism, which passes the staged child
  environment via `xcrun devicectl`
  ([run.sh](../../apps/client/run.sh#L58)). That flag was a proposal for the PoC.
  An iPad run still needs to validate the Metal calls, texture views,
  filtering, GPU timings, and change in actual allocated memory.

## T009-I: BC1 direto no runtime

1. **Mips, caminho existente no fallback.** BC nativo e ASTC LDR têm
   filtragem, e o blit de mipmaps exige também um formato renderizável.
   Porém, `newTexture` aloca com o descriptor físico. Para BC1, esse
   descriptor leva RGBA8 linear ou sRGB e preserva usage e níveis. O shim
   guarda o formato BC solicitado em metadados. Antes do delta 1,
   `spBCGenerateMipmaps` encaminhava o objeto ao Metal sem consultar
   esses metadados. Assim, uma
   textura solicitada como BC1, fisicamente RGBA8, com mais de um mip,
   pode receber mipmaps gerados no fallback. O mascaramento de formato
   para o cliente não altera o backing que executa o blit. A contagem de
   níveis no histograma indica alocação e não distingue upload de geração.
   O código demonstra a possibilidade, e a frequência no jogo permanece
   desconhecida. Recusar esse blit numa textura compacta poderia deixar
   níveis sem os dados que o jogo espera. [Criação](spbcfallback.m#L1206),
   [metadados](spbcfallback.m#L1054), [mapeamento](spbcdecode.c#L28),
   [hook de mipmaps](spbcfallback.m#L1770),
   [requisitos Metal](https://developer.apple.com/documentation/metal/mtlblitcommandencoder/generatemipmaps%28for%3A%29),
   [capacidades](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf).
2. **Uploads, grade confirmada.** Os dois `replaceRegion` e os dois uploads
   buffer → textura passam por `SPBCMakeLayout`. X/Y começam em múltiplos
   de quatro. Um tamanho parcial termina na borda do mip, inclusive quando
   o chamador arredonda o tamanho dentro do mesmo número de blocos. O
   layout valida pitches e, no blit, o shim confere o fim contra o tamanho
   do buffer. As divisões internas do tiler são múltiplos de quatro e o
   último tile herda a borda. Slices e níveis são encaminhados
   individualmente. Cada bloco BC1 tem todos os dados para um bloco ASTC
   4×4, sem ler texels vizinhos. No destino ASTC, o tiler calcula
   os pitches e tamanhos por linhas de blocos.
   [Replace](spbcfallback.m#L844), [blit](spbcfallback.m#L1527),
   [slices e níveis](spbcfallback.m#L1629), [layout e tiles](spbclayout.c#L70),
   [regiões comprimidas no Metal](https://developer.apple.com/documentation/metal/mtltexture/replace%28region%3Amipmaplevel%3Awithbytes%3Abytesperrow%3A%29).
3. **Readback, rejeição confirmada.** Ambos os `getBytes` do cliente
   rejeitam readback nas texturas convertidas, e ambos os blits textura →
   buffer rejeitam pela presença de metadados BC. As mesmas verificações
   cobrem o backing ASTC com esses metadados.
   [Readback CPU](spbcfallback.m#L927), [readback por blit](spbcfallback.m#L1755).
4. **Views, compatibilidade confirmada.** Os quatro seletores aceitam
   apenas o mesmo `SPBCKind` e escolhem a variante linear ou sRGB do
   backing da textura.
   O Metal admite views entre as duas variantes do mesmo formato
   comprimido. ASTC 4×4 LDR e sRGB podem compartilhar o backing, sujeitos
   às regras Metal de usage e da view solicitada.
   [Views do shim](spbcfallback.m#L965),
   [compatibilidade Metal](https://developer.apple.com/documentation/metal/mtltexture/maketextureview%28pixelformat%3A%29).
5. **Cópias, guarda física necessária.** Os três seletores textura →
   textura já compartilhavam uma guarda baseada no RGBA8 derivado do formato
   solicitado. Duas BC1 com o mesmo formato físico ASTC podem usar o blit
   de mesmo formato. O filtro de elegibilidade permite combinações
   mistas, por exemplo, textura standalone e textura de heap. A guarda
   anterior deixaria passar duas BC1 da mesma variante. A nova guarda
   checa os formatos físicos reais e recusa o par misto ou LDR ↔ sRGB
   com contador, antes de encaminhar a cópia. [Guarda e seletores](spbcfallback.m#L1665).

Nos três grupos da amostra (512, 256 e 128), a soma observada em RGBA8 foi
830,24 MiB alocados. Aplicar idealmente a razão de 4:1 aos três grupos
daria 207,56 MiB em ASTC e uma economia estimada de 622,68 MiB.
Para uma textura quadrada 512² com dois níveis (512² + 256²), o layout
lógico custa 1.310.720 B em RGBA8 e 327.680 B em ASTC. A estimativa sobre
a amostra supõe elegibilidade integral e ignora diferenças de padding.
A alocação Metal, o footprint, FPS/p95 e o efeito do RGB transparente na
filtragem e composição exigem teste no iPad. O alfa punch-through é exato
no PoC, mas o RGB transparente do BC1 pode passar de preto ao endpoint
mais escuro. A tabela acima registra o custo do codec no host.

**Decisão do delta 1.** O cliente publicado funciona com BC nativo no
macOS, onde o blit de mipmaps em BC1 é inválido. O piloto assume que o
cliente também não depende desse blit no iPad. O contador `mipgenBC` e o
primeiro log com formato e dimensões cobrem todas as chamadas BC no
fallback. RGBA8 continua encaminhando o blit. ASTC o recusa e registra
`SP_BC_COMPACT reject op=mipgen`. Uma ocorrência no iPad comprova que
o cliente acionou o caminho e exige verificar se os níveis recusados
eram necessários.

`SP_BC_COMPACT=1` ativa `bc-fallback-rgba8+astc-bc1` em dispositivos
no fallback com suporte à família Apple2. A decisão é tomada na
alocação de cada BC1 standalone elegível. O staging mantém a política
de reserva e a vida útil existentes, com pitch ASTC de 16 B por bloco.
No resumo, `live` e `total` contam raízes, `opaque` e `punch` contam
blocos acumulados, e `msPerOutputMiB` usa bytes ASTC transcodificados.
`astcAllocated` vem de `allocatedSize`, `rgbaLayout` é a conta lógica
RGBA8 das mesmas texturas vivas, e `savedEstimate` é a diferença.
`SP_BC_HIST` e `SP_BC_TOP` usam o formato físico real.

No Ryzen 5 4600G com GCC -O1, o microbench de 1024² em
`shims/metal/tests/run.sh` mediu 652 MPix/s opaco e 86 MPix/s
punch-through. Os testes de referência verificaram alfa exato e erro
RGB visível de até 1 por canal em linear e sRGB. Um texel transparente
sintético passou de RGB (0, 0, 0) para (0, 131, 0) com alfa 0 nos
dois perfis. O maior canal transparente observado foi 255.

## T009-J: BC2/BC3

T009-JC mantém 132–135 em RGBA8 linear/sRGB. A escolha do backing teria
de ocorrer em `newTexture*`, antes dos dados, para 2D, array, e cube
standalone com usage restrito a ShaderRead/PixelFormatView. Heap, IOSurface,
e alias de buffer ficam fora. Uma imagem boa no primeiro upload não
garante que a mesma representação sirva para mips e replaces posteriores.

- **ASTC 4×4 direto.** O protótipo existente usa CEM 12, um plano RGB e
  um plano alfa, grade 4×4, e três pesos por plano. São 52 bits de pesos
  e 19 de cabeçalho/seletor. Dos 57 restantes, 56 armazenam os oito
  endpoints de 7 bits. O alfa binário é exato, inclusive quando o bloco
  contém apenas 0 ou 255. Os outros valores sofrem quantização de endpoint
  e de peso. O RGB aproxima os dois índices intermediários de BC2/BC3
  pelo mesmo peso. Quatro pesos por plano já custam 64 bits e deixam
  45 para endpoints. Usar oito níveis para BC3 deixa 13 bits para CEM
  12, cujo mínimo é 21. Os 16 níveis independentes de BC2 esgotam os
  128 bits só em pesos. Reduzir a grade economiza bits ao custo de
  interpolar espacialmente máscaras e detalhes. Partições podem ajudar
  em certas bordas, sujeitas às máscaras predefinidas e ao custo de
  endpoints por partição. Luminância/alfa economiza endpoints em
  blocos compatíveis e restringe o RGB. Essas alternativas de modo não
  foram prototipadas. ASTC 4×4 tem variantes LDR e sRGB.
  [Implementação](spbcastc.c#L171) · [Khronos](https://registry.khronos.org/DataFormat/specs/1.4/dataformat.1.4.pdf)
- **16 bpp.** A tabela Metal marca os formatos empacotados como
  filtráveis nas famílias Apple2 em diante. ABGR4, A1BGR5 (também
  BGR5A1 com outra ordem de bits), e B5G6R5 têm somente variantes
  lineares. Isso limita a alocação a 132/134 e impede a view linear ↔
  sRGB da família. ABGR4 representa exatamente os 16 níveis do alfa
  BC2. Em BC3, o arredondamento para o nível de 4 bits mais próximo
  mantém os extremos e tem erro de até 8. A1BGR5 reduz o alfa a uma
  máscara e B5G6R5 amostra alfa 1. A avaliação host modela quantização
  UNorm por canal.
  [Formatos Metal](https://developer.apple.com/documentation/metal/mtlpixelformat) · [Tabela de capacidades Metal](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf)
- **RGBA8.** É a referência. O decoder escreve os texels como RGBA8,
  mantendo o perfil físico linear ou sRGB. O custo lógico é 4 B/texel.
  [Mapeamento](spbcdecode.c#L28)

### Medições

Ryzen 5 4600G, GCC 15.2 -O1, uma thread, imagens 1024², 16 iterações,
tempo CPU de BC até o buffer físico, com decode de validação fora do
cronômetro. RGBA8 mede o mesmo loop de blocos como referência de custo.
O benchmark gera gradiente opaco, textura granulada, folhagem com máscara
elíptica binária e grão, rampas de alfa suaves e curtas, e glifos com
cobertura intermediária. Ajusta os endpoints BC por bloco e quantiza
os índices contra as paletas BC. A entrada aleatória usa o mesmo
xorshift e seed do benchmark acima. Todo erro é relativo a BC
decodificado em bytes, antes da transferência sRGB.

ASTC linear e sRGB deram os mesmos resultados à precisão da tabela
abaixo. Cada célula de erro é PSNR em dB / erro máximo por canal.
O erro de alfa nos texels de referência 0 e 255 foi zero no ASTC,
ABGR4, A1BGR5, e RGBA8 em todas as imagens.

| Imagem | ASTC RGB | ASTC alfa BC2 | ASTC alfa BC3 | ASTC MPix/s BC2 / BC3 | ABGR4 RGB | ABGR4 alfa BC3 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Gradiente | 49,99 / 2 | ∞ / 0 | ∞ / 0 | 60,25 / 57,32 | 34,61 / 8 | ∞ / 0 |
| Ruído | 32,60 / 10 | ∞ / 0 | ∞ / 0 | 59,15 / 58,64 | 34,52 / 8 | ∞ / 0 |
| Folhagem | 32,63 / 9 | ∞ / 0 | ∞ / 0 | 57,38 / 56,30 | 33,82 / 8 | ∞ / 0 |
| Rampa alfa | 49,15 / 2 | 50,88 / 1 | 39,64 / 6 | 60,84 / 60,40 | 36,35 / 8 | 34,61 / 8 |
| Texto/UI | 52,90 / 1 | 26,22 / 43 | 23,59 / 56 | 58,20 / 56,74 | 33,58 / 8 | 42,99 / 4 |
| Aleatória | 25,83 / 44 | 18,04 / 60 | 20,75 / 64 | 46,21 / 46,65 | 34,49 / 8 | 34,92 / 8 |

ABGR4 deu alfa BC2 ∞ / 0 em todas as imagens. Em A1BGR5, RGB ficou
em 41,62–46,13 dB com erro ≤ 4 nas realistas e 42,39 / 4 na aleatória.
Na rampa, alfa BC2/BC3 ficou em 10,95 dB / 119 e 10,86 dB / 127. Na
aleatória, 11,10 dB / 119 e 10,48 dB / 127. B5G6R5 deu RGB ≥ 43,38 dB
com erro ≤ 4 nas realistas e 44,78 / 4 na aleatória. Na folhagem, o
alfa ficou em 2,00 dB / 255, inclusive erro 255 na máscara. Na
aleatória, deu 4,63 dB / 255 em BC2 e 4,77 dB / 255 em BC3. RGBA8
deu ∞ / 0 nos dois canais de medição, com erro zero na máscara.

| Codec | MPix/s realistas BC2 / BC3 | MPix/s aleatória BC2 / BC3 |
| --- | ---: | ---: |
| RGBA8 | 337–360 / 269–300 | 340 / 266 |
| ABGR4 | 190–192 / 170–173 | 193 / 160 |
| A1BGR5 | 189–199 / 173–177 | 196 / 170 |
| B5G6R5 | 198–213 / 178–193 | 208 / 180 |

Para o modo ASTC medido, 14,06% dos blocos BC2 e 50,00% dos BC3 de
texto/UI excedem o limite de alfa. No ruído e na folhagem, mesmo uma
correção perfeita precisaria substituir pelo menos 72,69% dos blocos
para alcançar 40 dB. Esse limite resulta da remoção dos blocos em ordem
decrescente de erro RGB quadrático até atingir o orçamento global da
imagem. Só essa parcela exige pelo menos 36,35 MPix/s do fallback
para alcançar 50 MPix/s no total, mesmo com custo direto zero.
Usando como referência o throughput histórico de astcenc
fastest em blocos aleatórios (1,14/1,25 MPix/s), codificar só 72,69% dos
blocos já projetaria cerca de 1,6/1,7 MPix/s, antes do custo direto.
Essa é uma projeção, pois o custo do fallback varia com o conteúdo.
O ambiente não conseguiu baixar astcenc para uma medição híbrida.
Um fallback por bloco teria de emitir ASTC válido no mesmo backing e
demonstrar qualidade e velocidade no conjunto. Mantendo RGBA8 nas
texturas inteiras, o shim nunca depende dessa correção.

### Decisão e memória

Nenhum candidato medido satisfaz os gates. O ASTC direto perde textura
fina e altera a cobertura de bordas antialias. ABGR4 introduz degraus
de cor, A1BGR5 recorta o alfa gradual, e B5G6R5 torna opacas as máscaras.
A escolha mantém o runtime e a validação Metal existentes.

Se `R = R132 + R133 + R134 + R135` for a soma lógica dos bytes RGBA8
das raízes elegíveis, o ganho entregue é zero. Para um ASTC futuro, a
economia lógica exata é `R − Σ(16 × ceil(w/4) × ceil(h/4))`, somando
por mip e slice. Para dimensões alinhadas, isso é `0,75R`, com redução
de 4:1. Uma opção 16 bpp teria economia `0,5 × (R132 + R134)` e
redução 2:1 nessa parcela linear. As fórmulas excluem padding Metal.
O iPad precisa fornecer `SP_BC_HIST bc=132..135` para estimar o
volume por formato e categoria. Validação, bytes físicos, latência,
e impacto visual da amostragem de um candidato futuro exigiriam
execução no dispositivo.

Reprodução do microbench a partir da raiz:

```sh
bench=$(mktemp -d)
gcc -std=c11 -Wall -Wextra -Werror -O1 -Ishims/metal \
    shims/metal/{spbcdecode,spbclayout,spbcastc}.c \
    shims/metal/tests/bench_bc_alpha.c -lm -o "$bench/bench"
"$bench/bench"
```

BC1 passou pela suíte existente antes e depois. Um comparador compilado
contra `b687ee1` e contra a worktree produziu 16.000.000 bytes
idênticos por `cmp`, com um milhão de blocos, seed `0x18092001`,
e casos de quatro cores, três cores, punch-through, e endpoints iguais.
O SHA-256 de ambas as saídas foi
`65047ca9c105277f374eb104de00744947a252f0af9e1b3fc29952428ab4f05c`.
`git diff` contra `b687ee1` confirma que os arquivos de runtime e
testes BC1 permanecem byte a byte iguais.
