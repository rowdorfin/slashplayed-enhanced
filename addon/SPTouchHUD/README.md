# SPTouchHUD 5.0 para Forever

Em **Settings → Controls**, ative **Controles touchscreen** e selecione **HUD 5.0 (addon SPTouchHUD)**. No jogo, o botão maior usa ataque automático ou a ação escolhida. Os seis botões em arco mostram os ícones, a recarga, as cargas, a contagem de itens e o estado de alcance e disponibilidade. Toque em **1/N** para percorrer as páginas ocupadas dos três conjuntos. Os conjuntos iniciais cobrem as oito barras.

Abra **⚙ → Editar HUD**, **Settings → AddOns → SPTouchHUD** ou digite **/sphud**.

- Em **Escolher ações**, toque em **Principal** ou em um dos seis botões da página atual. Escolha uma ação pelo nome e ícone, inclusive macros e itens que estejam na barra. Em **Principal**, use **Ataque automático** para restaurar a ação inicial. Uma posição da barra principal acompanha a página e a postura. Uma posição das demais barras é fixa. Se a posição principal estiver vazia, o botão mostra um traço.
- Em um botão secundário, escolha uma ação para substituir a atual ou preencher um espaço livre. **Mover antes**, **Mover depois** e **Remover ação** organizam o conjunto. A lista compacta as posições vazias, então remover uma ação puxa as seguintes.
- **Mover botões** abre a edição de geometria. Arraste um botão ou toque nele e depois numa posição livre. **Menor**, **Maior** e **Opacidade** alteram o botão selecionado. **Restaurar botões** repõe as posições, tamanhos e transparências individuais.
- **Avançado** edita o nome, a cor e as posições de cada conjunto. O campo aceita listas como `1:3,2:1-4,5:9` com até 48 posições por conjunto.
- Use o puxador para mover o grupo e **Escala**, **Opacidade** e **Aplicar** para ajustar o HUD. Os presets **iPhone MMORPG**, **iPhone compacto**, **iPad touchscreen**, **Canhoto** e **HUD 2.0 clássico** aplicam a geometria e mantêm as escolhas de ações.
- Para jogar com a mão esquerda, selecione **Canhoto** também no menu **···** dos controles de toque. Nesse menu, use **Mover controles de toque** e segure a alça do joystick para reposicioná-lo. Em **Settings → Controls → Joystick** ficam tamanho, zona morta, centro fixo ou flutuante e modo analógico.

A migração da 4.0 preserva os conjuntos e a ordem, o lado, a escala, a opacidade e a habilitação. Os deslocamentos e tamanhos individuais são restaurados para acomodar a nova geometria. O chat, o rastreador e as barras originais continuam sob controle do jogo. Use as opções de chat e o Edit Mode disponíveis no cliente para mudanças de layout.

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

**Implementação.** Fora de combate, o Lua consulta a ocupação e compila as páginas 1–15 da barra principal junto com os slots fixos selecionados. Os slots comprovadamente vazios saem da lista. Eventos de slot, página, talentos, forma e furtividade agrupam a recompilação em uma atualização. Em combate, o controlador seguro escolhe a lista compilada da página atual e volta à primeira página do conjunto se a anterior não existir. A ocupação e a geometria aguardam o fim do combate. Veículo, override, forma temporária, e páginas fora da faixa compilada mantêm as posições selecionadas da barra principal para que ações que surjam em combate continuem acessíveis.

**HIPÓTESE a validar no aparelho.** O driver e as consultas de bônus precisam refletir cada forma em Forever no momento da troca. **Interagir** depende do botão contextual de gamepad disponível no cliente e do aceite do par de chamadas `/click` com toque. Valide também o **Ataque automático**, **Alvo**, o gesto de arrastar do editor, e as margens com a escala real da interface. [MainActionBarFrame.lua][gamepad] · [SecureTemplates.lua][actions]

## Gamepad virtual experimental

O joystick padrão envia WASD com diagonais. O modo analógico usa um controle iOS dentro do Slashplayed. Com **Joystick analógico** e **Gamepad virtual experimental** ativados, o primeiro toque no joystick conecta um perfil com dois eixos direcionais e os botões **A**, **LB**, **RB** e **X**. O botão de câmera dedicado fica ao lado de A. Arraste dentro dele para inclinar o eixo e solte para voltar ao centro. Os atalhos e as camadas permanecem sob controle das configurações nativas do Forever.

Confirme no jogo com **/sphudpad** antes e depois de tocar no joystick. Se necessário, habilite o gamepad pelo menu do Forever ou manualmente com **/console GamePadEnable 1**. Anote o valor original de **GamePadEnable** antes de alterá-lo. Em caso de falha de conexão no iOS, o joystick envia WASD. Se o iOS conectar e o guest ignorar o controle, desligue o modo experimental ou o modo analógico no Settings. As habilidades do HUD seguem vinculadas a ações seguras da barra do jogo. O protótipo precisa ser validado com o cliente real e com controle físico Bluetooth.

## Instalação

O launcher instala o HUD em Forever no iOS quando selecionado. O fallback para os controles nativos só remove arquivos distribuídos com tamanho e SHA-256 conhecidos. Para instalação manual, copie o `.toc` e o `.lua` para `Interface/AddOns/SPTouchHUD/`.

[bars]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_ActionBar/Shared/MultiActionBars.xml#L45-L237
[actions]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_FrameXML/SecureTemplates.lua
[paging]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_ActionBarController/ActionBarController.lua#L156-L173
[restricted]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_RestrictedAddOnEnvironment/RestrictedEnvironment.lua#L129-L143
[driver]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_RestrictedAddOnEnvironment/SecureStateDriver.lua
[gamepad]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_GamepadActionBars/MainActionBarFrame.lua#L499-L545
