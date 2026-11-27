# SPTouchHUD 4.0 para Forever

Em **Settings → Controls**, ative **Controles touchscreen** e escolha **SPTouchHUD** em **Barra de habilidades**. O preset **iPhone MMORPG** traz seis habilidades em arco, **Atacar**, **Alvo**, e **Interagir**, acima da faixa do botão nativo de pulo. **1**, **2**, e **3** escolhem o conjunto. **›** avança para a próxima página ocupada do conjunto. Os conjuntos iniciais cobrem as oito barras, inclusive itens e macros. Ícones, recarga, cargas, contagem, e cores de alcance e disponibilidade vêm dos slots do jogo.

Abra **··· → Editar HUD**, **Settings → AddOns → SPTouchHUD**, ou `/sphud`.

- **Slots** monta a lista na ordem dos toques. Para mudar a ordem, remova e reinsira a posição. O campo aceita listas como `1:3,2:1-4,5:9`. Cada conjunto aceita até 48 posições.
- **Mover botões** abre a edição fora de combate. Arraste um botão ou toque nele e depois numa posição livre. Use **Menor** e **Maior** para ajustar o tamanho. **Restaurar botões** repõe os nove botões. Os alvos precisam caber na área do grupo sem sobreposição.
- Use o puxador para mover o grupo e **Escala**, **Opacidade**, e **Aplicar** para ajustar sua apresentação. **Restaurar padrão** repõe a geometria iPhone MMORPG e conserva os conjuntos. Os presets incluem **Canhoto** e a grade **HUD 2.0 clássico**.
- No modo **Canhoto**, use também **Trocar lado do joystick** na engrenagem UIKit. O joystick, o pulo, e os ajustes de câmera pertencem ao UIKit.

O layout, os conjuntos, e as posições individuais ficam em `SPTouchHUDCharDB`. A migração v4 repõe a geometria antiga e conserva os conjuntos válidos, inclusive em registros incompletos. A habilitação fica em `SPTouchHUDDB`. As barras originais e os atalhos de teclado e mouse ficam disponíveis. Ocultá-las foi omitido porque não há um caminho validado para desativar e restaurar os alvos do mouse das barras protegidas sem risco de taint.

## Slots e combate

**FATO (Forever 1.60.1, interface 16001).** O slot é `índice + (página − 1) × 12`. O botão seguro usa o atributo `action` e executa na soltura. O ambiente restrito expõe as consultas de página principal, bônus de forma, veículo, override, e forma temporária. A consulta `HasAction` também consta na lista restrita, mas o HUD só mede ocupação fora de combate. As barras adicionais usam os índices fixos abaixo. [MultiActionBars.xml][bars] · [SecureTemplates.lua][actions] · [ActionBarController.lua][paging] · [RestrictedEnvironment.lua][restricted] · [SecureStateDriver.lua][driver]

| Barra no editor | Frame | Página | Slots |
| --- | --- | ---: | ---: |
| 1 | MainActionBar | 1–6 ou especial | 1–72 ou `índice + (página especial − 1) × 12` |
| 2 | MultiBarBottomLeft | 6 | 61–72 |
| 3 | MultiBarBottomRight | 5 | 49–60 |
| 4 | MultiBarRight | 3 | 25–36 |
| 5 | MultiBarLeft | 4 | 37–48 |
| 6 | MultiBar5 | 13 | 145–156 |
| 7 | MultiBar6 | 14 | 157–168 |
| 8 | MultiBar7 | 15 | 169–180 |

**Implementação.** Fora de combate, o Lua consulta a ocupação e compila as páginas 1–15 da barra principal junto com os slots fixos selecionados. Os slots comprovadamente vazios saem da lista. Eventos de slot, página, forma, e furtividade atualizam a compilação. Em combate, o controlador seguro escolhe a lista compilada da página atual e volta à primeira página do conjunto se a anterior não existir. A ocupação e a geometria aguardam o fim do combate. Veículo, override, forma temporária, e páginas fora da faixa compilada mantêm as posições selecionadas da barra principal para que ações que surjam em combate continuem acessíveis.

**HIPÓTESE a validar no aparelho.** O driver e as consultas de bônus precisam refletir cada forma em Forever no momento da troca. **Interagir** depende do botão contextual de gamepad disponível no cliente e do aceite do par de chamadas `/click` com toque. Valide também os comandos **Atacar** e **Alvo**, o gesto de arrastar do editor, e as margens com a escala real da interface. [MainActionBarFrame.lua][gamepad] · [SecureTemplates.lua][actions]

## Instalação

O launcher instala o HUD em Forever no iOS quando selecionado. O fallback para os controles nativos só remove arquivos distribuídos com tamanho e SHA-256 conhecidos. Para instalação manual, copie o `.toc` e o `.lua` para `Interface/AddOns/SPTouchHUD/`.

[bars]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_ActionBar/Shared/MultiActionBars.xml#L45-L237
[actions]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_FrameXML/SecureTemplates.lua
[paging]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_ActionBarController/ActionBarController.lua#L156-L173
[restricted]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_RestrictedAddOnEnvironment/RestrictedEnvironment.lua#L129-L143
[driver]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_RestrictedAddOnEnvironment/SecureStateDriver.lua
[gamepad]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_GamepadActionBars/MainActionBarFrame.lua#L499-L545
