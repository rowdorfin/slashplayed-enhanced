# SPTouchHUD para Forever

Em **Settings → Controls**, ative **Controles touchscreen** e selecione **SPTouchHUD** em **Barra de habilidades** (a opção que antes se chamava **HUD 2.0**). Em Forever, o preset **iPhone MMORPG** traz seis posições por página. O primeiro slot ocupa o botão principal de 68 pt, e os cinco seguintes usam 50 pt no iPhone de referência. Cada alvo se estende 3 pt além da borda visual. Os botões **1**, **2**, e **3** abrem o primeiro grupo de slots de cada conjunto. O botão **›** percorre as páginas de seis slots do conjunto ativo. Os conjuntos iniciais cobrem as oito barras.

Abra **··· → Editar HUD**, **Settings → AddOns → SPTouchHUD**, ou `/sphud`. Use **Slots** para escolher posições em ordem e **Cor** para editar a cor de cada conjunto. Uma lista como `1:3,2:1-4,5:9` põe o terceiro botão da barra principal na posição maior, seguido pelos quatro primeiros da barra inferior esquerda e pelo nono da barra esquerda. Os três conjuntos aceitam até 48 posições cada. Use o puxador para arrastar o grupo, **Escala** para redimensionar, **Opacidade** para ajustar a transparência, e **Auxiliares** para ocultar o menu e Interagir. Os presets são **iPhone MMORPG**, **iPhone compacto**, **iPad touchscreen**, **Canhoto**, e **HUD 2.0 clássico**. O clássico exibe a grade e os atalhos do 2.0. **Restaurar padrão** repõe o preset iPhone MMORPG. O addon guarda o layout e os conjuntos por personagem em `SPTouchHUDCharDB` e a habilitação por conta em `SPTouchHUDDB`.

Cada soltura do usuário aciona uma vez o slot do botão seguro. Configure feitiços, itens, e macros nas barras do jogo. As cores indicam fora de alcance (vermelho), falta de recurso (azul), e ação indisponível (cinza). O HUD usa o atlas `CircleMask` do cliente quando disponível, com a máscara de retrato como alternativa. [TotemFrame.xml e TotemFrame.lua][mask]

Fora de combate, o addon registra quais slots estão comprovadamente vazios. Posições vazias somem sem deslocar as demais. Em combate, o código inseguro mantém a geometria, os atributos, e o registro de vazios congelados. A troca de conjunto, página, ou forma continua pelo estado seguro, que lê o registro anterior. Mudanças de ocupação ou configuração aguardam o fim do combate. As texturas, os indicadores, e os cooldowns continuam atualizando.

## Barras e slots confirmados

O código de referência é o dump do cliente **Forever 1.60.1** no tag `1.60.1` de Gethe (`d9c22e3`), correspondente à interface `16001` em `apps/client/flavors.plist`. O slot é `índice + (página − 1) × 12`. O controlador da Blizzard consulta o índice real de forma/furtividade, veículo, override e forma temporária. O HUD usa as mesmas consultas do ambiente restrito e aplica as páginas especiais só à barra principal. [MultiActionBars.xml, linhas 45–237][bars] · [SecureTemplates.lua, linhas 667–685][actions] · [ActionBarController.lua, linhas 156–173][paging] · [RestrictedEnvironment.lua, linhas 139–154][restricted]

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

## Compatibilidade das APIs

| Estado | API e comportamento | Fonte |
| --- | --- | --- |
| FATO | `SecureActionButtonTemplate` com `type=action` lê o atributo `action`; `useOnKeyDown=false` configura execução na soltura. `type=macro` suporta `macrotext`. | [SecureTemplates.xml][templates] · [SecureTemplates.lua, linhas 341–360, 450–463, 667–685, 792–820][actions] |
| FATO | `RegisterStateDriver`, `SecureHandlerStateTemplate`, `SecureHandlerClickTemplate`, `Execute`, `_onclick`, `ChildUpdate` e `_childupdate-slots` executam as trocas de estado e de conjunto. `ACTIONBAR_PAGE_CHANGED`, `UPDATE_BONUS_ACTIONBAR`, `UPDATE_SHAPESHIFT_FORM` e `UPDATE_STEALTH` disparam reavaliação do driver do cliente. | [SecureStateDriver.lua][driver] · [SecureHandlerTemplates.xml][handlerTemplates] · [SecureHandlers.lua][handlers] · [RestrictedFrames.lua, linhas 768–803][children] |
| FATO | `C_ActionBar.GetActionTexture`, `GetActionCooldown`, `GetActionCooldownDuration`, `GetActionCharges`, `GetActionDisplayCount`, `GetActionUseCount`, `IsUsableAction` e `IsActionInRange` usam o ID do slot. `Clear`, `SetCooldown` e `SetCooldownFromDurationObject` atualizam as espirais. `issecretvalue` protege as comparações; `FontString:SetText` aceita contagens secretas. | [ActionBarFrameDocumentation.lua][barapi] · [FrameAPICooldownDocumentation.lua][cooldown] · [SimpleFontStringAPIDocumentation.lua, linha 664][font] · [SecureTypes.lua][secrets] |
| FATO | `ACTIONBAR_SLOT_CHANGED`, `ACTIONBAR_UPDATE_COOLDOWN`, `ACTIONBAR_UPDATE_USABLE`, `SPELL_UPDATE_USABLE`, `SPELL_UPDATE_CHARGES`, `PLAYER_TARGET_CHANGED` e `UI_SCALE_CHANGED` atualizam a apresentação. Um único `C_Timer.NewTicker` usa `UnitExists("target")` para limitar a consulta de alcance ao período com alvo. | [ActionBarFrameDocumentation.lua][barapi] · [SpellBookDocumentation.lua][spellbook] · [UnitDocumentation.lua][unit] · [UIManagerDocumentation.lua][ui] · [UITimerDocumentation.lua][timer] |
| FATO | `InCombatLockdown`, `PLAYER_REGEN_DISABLED` e `PLAYER_REGEN_ENABLED` guardam alterações ao layout. `ADDON_LOADED` inicializa configurações e `PLAYER_ENTERING_WORLD` atualiza o HUD. | [RestrictedActionsDocumentation.lua][lockdown] · [UnitDocumentation.lua][unit] · [AddOnsDocumentation.lua][addons] · [SystemDocumentation.lua][system] |
| FATO | `ToggleAllBags`, `ToggleWorldMap`, `ToggleCharacter("PaperDollFrame")`, `ToggleQuestLog`, `PlayerSpellsUtil.ToggleSpellBookFrame` e `ChatFrameUtil.OpenChat` são os mesmos caminhos dos atalhos padrão. `Settings.RegisterCanvasLayoutCategory` e `RegisterAddOnCategory` integram o painel. `CreateFrame`, `UIParent`, regiões de textura/texto e scripts de frame seguem os widgets padrão. | [Bindings_Standard.xml, linhas 109–114 e 1220–1271][bindings] · [Blizzard_Settings.lua][settings] · [ActionButton.lua][actionbuttons] |
| FATO | `INTERACTTARGET` existe e chama `C_PlayerInteractionManager.InteractUnit("anyinteract")`, uma API restrita. `RunBinding` chamado pelo addon não autoriza a chamada protegida. O botão contextual do gamepad tem tratamento próprio para pressionar e soltar. | [Bindings_Standard.xml, linhas 1166–1182][bindings] · [PlayerInteractionManagerDocumentation.lua][interaction] · [RunBinding][binding-api] · [MainActionBarFrame.lua, linhas 499–545][gamepad] |
| HIPÓTESE a validar | O toque em **Interagir** encaminha um par fixo de press/release ao botão contextual do gamepad quando ele existe. Validar se o cliente permite o encaminhamento com mouse/toque; o addon desabilita esse botão quando o controle contextual está ausente. Validar também `/targetenemy`, `/startattack`, menus, páginas de forma/veículo e cooldowns sob restrição no aparelho. As globais legadas `GetActionTexture`, `GetActionCooldown`, `GetActionCount`, `IsUsableAction` e `IsActionInRange` são caminhos condicionais para builds divergentes. | [Sintaxe de /click][click] · [SecureTemplates.lua][actions] · [Condicionais do cliente][conditions] |

## Integração iOS

No modo SPTouchHUD, o joystick ocupa 23% do retângulo do jogo e o Lua usa os 68% seguintes. Pular ocupa 9% da largura, com mínimo de 64 pt a partir da borda da safe area. Quando o recorte lateral leva essa faixa para dentro dos 68%, o arco mantém os alvos acima de Pular nesse canto. O cálculo usa coordenadas do jogo e dispensa a escala de renderização. O joystick tem 120 pt por padrão e aceita centro fixo ou flutuante. A tecla Pular tem 42 pt de face e 48 pt de alvo. Autorun, quando habilitado no modo WASD, usa a seta dupla e se solta com novo toque, uso do joystick, ou perda de foco.

**···** abre mapa, bolsas, personagem, missões, grimório, chat, e opções do jogo. Na engrenagem UIKit, abra o teclado de chat, ajuste o zoom, exiba R e modificadores, ou mova os controles nativos. No preset **Canhoto**, use também **Trocar lado do joystick** nessa engrenagem para espelhar o UIKit. As faixas continuam válidas durante a troca. Os botões de teclado 1–0 e Tab ficam disponíveis pelo modo de controles nativos das configurações do launcher.

Um dedo no joystick fica fora do fluxo do ponteiro. Durante o arrasto de câmera, um segundo dedo que toca na área do jogo gera uma rotação de eventos direito-solta, clique esquerdo na posição do toque e direito-pressiona na âncora da câmera. Os deslocamentos da câmera seguem o primeiro dedo, inclusive durante o segundo toque. Um segundo dedo que se desloca pelo menos oito pontos desiste do clique. O modo de botões nativos mantém os acordes da T008-B.

O launcher já recebe o flavor em `sp_addons_place`. Ao iniciar Forever no iOS, instala o HUD se escolhido e volta aos botões nativos se a instalação falhar. No fallback, a remoção verifica tipo, tamanho e SHA-256 dos arquivos distribuídos. A instalação opera em `Interface/AddOns`. O SPTouchBars em `upstream/enhanced` (MIT) serviu como referência para o botão contextual. A migração de retirada do SPTouchBars continua ativa. O kit A16 e o build do cliente carregam o addon. Para instalação manual, copie o `.toc` e o `.lua` para `Interface/AddOns/SPTouchHUD/` e habilite o addon no jogo.

[bars]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_ActionBar/Shared/MultiActionBars.xml#L45-L237
[actions]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_FrameXML/SecureTemplates.lua
[templates]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_FrameXML/SecureTemplates.xml
[paging]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_ActionBarController/ActionBarController.lua#L156-L173
[restricted]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_RestrictedAddOnEnvironment/RestrictedEnvironment.lua#L139-L154
[driver]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_RestrictedAddOnEnvironment/SecureStateDriver.lua
[handlers]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_RestrictedAddOnEnvironment/SecureHandlers.lua
[handlerTemplates]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_RestrictedAddOnEnvironment/SecureHandlerTemplates.xml
[children]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_RestrictedAddOnEnvironment/RestrictedFrames.lua#L768-L803
[barapi]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_APIDocumentationGenerated/ActionBarFrameDocumentation.lua
[cooldown]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_APIDocumentationGenerated/FrameAPICooldownDocumentation.lua
[font]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_APIDocumentationGenerated/SimpleFontStringAPIDocumentation.lua#L664
[secrets]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_SharedXMLBase/SecureTypes.lua
[spellbook]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_APIDocumentationGenerated/SpellBookDocumentation.lua
[unit]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_APIDocumentationGenerated/UnitDocumentation.lua
[ui]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_APIDocumentationGenerated/UIManagerDocumentation.lua
[timer]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_APIDocumentationGenerated/UITimerDocumentation.lua
[lockdown]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_APIDocumentationGenerated/RestrictedActionsDocumentation.lua
[addons]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_APIDocumentationGenerated/AddOnsDocumentation.lua
[system]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_APIDocumentationGenerated/SystemDocumentation.lua
[bindings]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_FrameXML/Bindings_Standard.xml
[settings]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_Settings_Shared/Blizzard_Settings.lua
[actionbuttons]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_ActionBar/Shared/ActionButton.lua
[interaction]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_APIDocumentationGenerated/PlayerInteractionManagerDocumentation.lua
[gamepad]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_GamepadActionBars/MainActionBarFrame.lua#L499-L545
[click]: https://warcraft.wiki.gg/wiki/MACRO_click
[conditions]: https://warcraft.wiki.gg/wiki/Secure_command_options
[binding-api]: https://warcraft.wiki.gg/wiki/API_RunBinding

[mask]: https://github.com/Gethe/wow-ui-source/blob/1.60.1/Interface/AddOns/Blizzard_UnitFrame/Mainline/TotemFrame.lua#L50-L58
