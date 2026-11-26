# Slashplayed Companion A16

O Companion instala o Slashplayed por USB em um iPad ou iPhone. Usa a conta Apple para preparar o perfil, assina com zsign e instala o aplicativo. A variante A16 parte do Companion oficial 1.7.0 e acrescenta reutilização local da sessão Apple, logout local, interface em português brasileiro, seleção e verificação do kit, consulta e download da CI A16 e exportação USB de logs. A revogação automática de certificados foi removida.

Decisão de arquitetura — a GUI continua em egui/eframe.

## Compilar no Windows 11 x86_64

1. Instale o rustup com Rust **1.99.0**, alvo **`x86_64-pc-windows-msvc`**, e o Visual Studio Build Tools com **Desktop development with C++**, MSVC x64 e Windows SDK (`rc.exe`). Use o terminal de desenvolvimento **x64 Native Tools** para disponibilizar o compilador, o SDK e o `nmake`.
2. Instale o **Strawberry Perl** e informe seu executável nativo em `OPENSSL_SRC_PERL`. O crate `openssl-src` compila a libcrypto a partir do código-fonte. O terminal também precisa de Git e do Bash do Git for Windows para preparar os insumos.
3. Na raiz de uma cópia da tag **`v1.7.0`** com os scripts originais, rode no Git Bash:

   ```bash
   bash scripts/build-zsign.sh source
   bash scripts/fetch-font.sh
   ```

   O modo `source` obtém o zsign no commit fixado e aplica `scripts/zsign.patch`. Use a pasta resultante `work/zsign/src/zsign` na raiz da árvore A16 ou aponte `SP_ZSIGN_SRC` para ela. Esse modo prepara apenas o código-fonte, sem Xcode ou OpenSSL pré-compilado. O script da fonte usa `curl` e `sha256sum` ou `shasum` para obter e verificar os arquivos em `work/fonts`. A fonte é opcional para compilar e rodar, mas exigida no pacote.
4. Na árvore A16, a partir da raiz, em `cmd.exe` com as ferramentas x64:

   ```bat
   rustup toolchain install 1.99.0-x86_64-pc-windows-msvc
   set "OPENSSL_SRC_PERL=C:\Strawberry\perl\bin\perl.exe"
   rem Se o zsign preparado estiver em outra arvore, ajuste e descomente a linha.
   rem set "SP_ZSIGN_SRC=C:\caminho\work\zsign\src\zsign"
   cd apps\companion-a16
   cargo +1.99.0-x86_64-pc-windows-msvc build --release --locked --target x86_64-pc-windows-msvc
   ```

   Com dependências e fontes já obtidas, acrescente `--offline`. A compilação normal gera os dois executáveis em `target\x86_64-pc-windows-msvc\release`. Para usar Goodmountain, copie `Goodmountain-Regular.otf` para o lado do executável, conservando o nome. Para empacotar, disponibilize o OTF e `LICENSE.md` em `work/fonts` na árvore A16 e, na raiz A16, execute `PYTHON=python bash apps/companion-a16/package.sh x86_64-pc-windows-msvc dist` com Python 3, o componente `rust-docs` da toolchain 1.99.0 (para os avisos da biblioteca padrão) e o `tar.exe` do Windows disponíveis. Se definiu `SP_ZSIGN_SRC` no terminal de compilação, exporte o caminho também para o Git Bash.

## Executar

No Windows, instale Apple Devices ou o iTunes com Apple Mobile Device Support. No Linux, use o serviço usbmuxd. Conecte e desbloqueie o aparelho, autorize o computador quando solicitado e ative o Modo de Desenvolvedor para instalar.

Abra `slashplayed-companion.exe` no Windows ou `slashplayed-companion` em Linux e macOS. Selecione o ZIP por caminho, arraste-o para a janela ou use **Escolher…** no Windows. Clique em **Verificar** após editar o caminho ou o hash. A GUI usa o `SHA256SUMS` ao lado do ZIP e aceita um SHA-256 colado. Se fornecer ambos, os dois precisam coincidir. Sem referência, a GUI informa que apenas calculou o hash. Uma divergência bloqueia a instalação. Builds com `SP_KIT_SHA256` também podem usar o kit oficial fixado quando o caminho está vazio. **Kit da CI no GitHub** consulta o workflow e preenche o caminho com o ZIP verificado após o download. Informe o Apple ID para consultar sua sessão local. **Copiar log** copia o log sanitizado da instalação.

Exemplos no terminal. No Windows, use `slashplayed-cli.exe`:

```sh
slashplayed-cli devices
slashplayed-cli install --kit /caminho/slashplayed-device-kit.zip
slashplayed-cli logout conta@exemplo.com
slashplayed-cli logout conta@exemplo.com --forget-key
slashplayed-cli kit-ci
slashplayed-cli kit-ci --out ./kit-a16
slashplayed-cli logs --out ./logs-ipad --bundle-id EQUIPE.slashplayed --udid UDID
slashplayed-cli logs --out ./logs-ipad --team EQUIPE --jetsam-limit 10
```

O download da CI exige token com acesso de leitura aos artefatos do repositório. A consulta pode ser anônima quando a API permitir. A ordem é `GH_TOKEN`, `GITHUB_TOKEN`, `gh auth token` e token colado ou guardado pela GUI. Artefatos expirados ficam indisponíveis. O ZIP é conferido contra o `SHA256SUMS` do artefato. A CLI grava ZIP e checksum em `--out` e mostra `app_sha` se presente. Abra o ZIP com `install --kit`.

## Dados locais e limitações

- O `state.json` registra bundle ID, equipe e validade da última instalação em `%LOCALAPPDATA%\SlashplayedA16`, `~/Library/Application Support/SlashplayedA16` no macOS ou `${XDG_CONFIG_HOME:-$HOME/.config}/SlashplayedA16` no Linux. A GUI consulta perfis do bundle ID conhecido via `misagent`. Quando não consegue obter um perfil, exibe a validade registrada na última instalação, se disponível. A data local pode ficar desatualizada após uma renovação no aparelho.
- Sessões no Windows ficam no subdiretório `sessions`, protegidas por DPAPI. Em Linux e macOS, ficam no gerenciador de credenciais. A chave RSA, a senha optativa e o token GitHub optativo também usam o gerenciador do sistema. Uma rejeição Apple aparece na GUI durante a execução em que foi detectada. Como a sessão rejeitada é removida, a próxima abertura mostra que não há sessão guardada. Veja [SECURITY-A16.md](SECURITY-A16.md).
- **Exportar logs** copia os arquivos `spconsole*.log` e `sp-metal-diag*.log` da raiz de Documents exposta por `house_arrest`. Usa o bundle ID da última instalação ou, se disponível, `<team>.slashplayed`. Na CLI, `--bundle-id` tem precedência. O serviço pode recusar acesso por falta de confiança USB, app ausente ou compartilhamento de arquivos indisponível. A exportação segue com os relatórios de falha e informa cada limitação.
- A exportação percorre as pastas visíveis de `com.apple.crashreportcopymobile`. Copia nomes relacionados ao Slashplayed, WoW, World of Warcraft ou spguest, mais os Jetsam mais recentes por data de modificação (20 por padrão). O console unificado e os relatórios ainda não expostos pelo serviço ficam fora da exportação. Nenhum arquivo é removido do aparelho. Use um diretório de saída novo ou vazio. O manifesto lista nomes relativos, tamanhos e hashes SHA-256 dos arquivos efetivamente copiados.
- A cópia USB é bruta. As restrições de acesso e a disponibilidade de cada tipo de log variam com o aparelho, a versão do iOS/iPadOS e a compilação instalada. O Companion A16 atende iPhone e iPad. A instalação em Vision Pro continua no Companion para Mac.
