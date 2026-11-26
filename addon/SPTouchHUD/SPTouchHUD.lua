local addonName = ...
local barPages = {1, 6, 5, 3, 4, 13, 14, 15}
local presets = {
    {"iPhone compacto", 0.85, 4, "1:1-8", "2:1-8", "3:1-8"},
    {"iPhone MMORPG", 1, 6, "1", "2", "3,6"},
    {"iPad touchscreen", 1.2, 8, "1,2", "3,4", "5,6,7,8"},
}
local maxButtons = 48
local layoutFields = {
    {"scale", 0.55, 1.8, 1}, {"opacity", 0.2, 1, 0.94}, {"spacing", 0, 24, 5},
    {"columns", 4, 10, 6}, {"count", 1, maxButtons, maxButtons},
}
local colors = {"4bdace", "ffba60", "c9a2ff"}
local root, buttons, switches, utilities, editor, pending, ticker
local account, layout
local events = CreateFrame("Frame")
local api = C_ActionBar or {}

local function readable(value)
    return not issecretvalue or not issecretvalue(value)
end

local function bound(value, fallback, lo, hi)
    value = tonumber(value)
    if not value or value ~= value then return fallback end
    return math.max(lo, math.min(hi, value))
end

local function parseSlots(text)
    local slots, seen = {}, {}
    for token in text:gmatch("[^,%s]+") do
        local bar, first, last = token:match("^(%d):(%d+)%-(%d+)$")
        if not bar then bar, first = token:match("^(%d):(%d+)$") end
        if not bar then bar = token:match("^(%d)$"); first, last = 1, 12 end
        bar, first = tonumber(bar), tonumber(first)
        last = tonumber(last) or first
        if not barPages[bar] or not first or first < 1 or last > 12 or first > last then return end
        for index = first, last do
            local slot = (barPages[bar] - 1) * 12 + index
            if not seen[slot] then
                if #slots == maxButtons then return end
                slots[#slots + 1], seen[slot] = slot, true
            end
        end
    end
    return slots
end

local function usePreset(index)
    local preset = presets[index]
    layout = {x = 0.79, y = 0.39, scale = preset[2], opacity = 0.94, spacing = 5,
        columns = preset[3], count = maxButtons, left = false, sets = {}}
    for i = 1, 3 do
        layout.sets[i] = {label = "Conjunto " .. i, color = colors[i], text = preset[3 + i]}
    end
    SPTouchHUDCharDB = layout
end

local function validColor(color)
    return type(color) == "string" and #color == 6 and color:match("^%x+$")
end

local function cleanLabel(label, index)
    label = type(label) == "string" and label:gsub("|", "") or ""
    return label ~= "" and label or "Conjunto " .. index
end

local function loadLayout()
    layout = SPTouchHUDCharDB
    if type(layout) ~= "table" or type(layout.sets) ~= "table" or #layout.sets ~= 3 then
        usePreset(2)
        return
    end
    layout.x, layout.y = bound(layout.x, 0.79, 0, 1), bound(layout.y, 0.39, 0, 1)
    layout.left = layout.left == true
    for i, spec in ipairs(layoutFields) do
        local value = bound(layout[spec[1]], spec[4], spec[2], spec[3])
        layout[spec[1]] = i >= 4 and math.floor(value) or value
    end
    for i = 1, 3 do
        local set = type(layout.sets[i]) == "table" and layout.sets[i] or {}
        layout.sets[i] = {
            label = cleanLabel(set.label, i),
            color = validColor(set.color) and set.color or colors[i],
            text = type(set.text) == "string" and parseSlots(set.text) and set.text or presets[2][3 + i],
        }
    end
end

local function updateTint(button, refreshUsable)
    local slot = button:GetAttribute("action")
    if not slot or not button.icon:GetTexture() then return end
    local range = api.IsActionInRange or IsActionInRange
    local inRange
    if range and UnitExists("target") then inRange = range(slot, "target") end
    if refreshUsable then
        local usable = api.IsUsableAction or IsUsableAction
        button.canUse, button.noResource = true, false
        if usable then button.canUse, button.noResource = usable(slot) end
    end
    local canUse, noResource = button.canUse, button.noResource
    if readable(inRange) and (inRange == false or inRange == 0) then
        button.icon:SetVertexColor(1, 0.35, 0.35)
    elseif readable(noResource) and noResource then
        button.icon:SetVertexColor(0.35, 0.55, 1)
    elseif readable(canUse) and not canUse then
        button.icon:SetVertexColor(0.45, 0.45, 0.45)
    else
        button.icon:SetVertexColor(1, 1, 1)
    end
end

local function setCooldown(frame, active, start, duration, rate)
    if readable(active) and active and readable(start) and readable(duration) and readable(rate) then
        frame:SetCooldown(start, duration, rate or 1)
    else
        frame:Clear()
    end
end

local function updateCooldown(button)
    local slot = button:GetAttribute("action")
    if not slot or not button.icon:GetTexture() then
        button.cooldown:Clear()
        button.charge:Clear()
        button.count:SetText("")
        return
    end
    local duration
    if api.GetActionCooldownDuration and button.cooldown.SetCooldownFromDurationObject then
        duration = api.GetActionCooldownDuration(slot)
    end
    if readable(duration) and duration then
        button.cooldown:SetCooldownFromDurationObject(duration)
    elseif api.GetActionCooldown then
        local info = api.GetActionCooldown(slot)
        if readable(info) and type(info) == "table" then
            setCooldown(button.cooldown, info.isActive, info.startTime, info.duration, info.modRate)
        else
            button.cooldown:Clear()
        end
    elseif GetActionCooldown then
        local start, length, enabled, rate = GetActionCooldown(slot)
        setCooldown(button.cooldown, readable(enabled) and (enabled == 1 or enabled == true), start, length, rate)
    else
        button.cooldown:Clear()
    end

    local charges = api.GetActionCharges and api.GetActionCharges(slot)
    if readable(charges) and type(charges) == "table" then
        setCooldown(button.charge, charges.isActive, charges.cooldownStartTime, charges.cooldownDuration, charges.chargeModRate)
    else
        button.charge:Clear()
    end

    if api.GetActionDisplayCount then
        button.count:SetText(api.GetActionDisplayCount(slot))
    else
        local count = (api.GetActionUseCount or GetActionCount)
        count = count and count(slot)
        button.count:SetText(readable(count) and count and count > 0 and count or "")
    end
end

local function refresh(button)
    local slot = button:GetAttribute("action")
    local texture = api.GetActionTexture or GetActionTexture
    button.icon:SetTexture(slot and texture and texture(slot) or nil)
    updateCooldown(button)
    updateTint(button, true)
end

-- The restricted environment exposes these same page APIs as globals.
local updatePage = [=[
    local page = GetActionBarPage and GetActionBarPage() or tonumber(newstate) or 1
    if HasVehicleActionBar and HasVehicleActionBar() and GetVehicleBarIndex then
        page = GetVehicleBarIndex()
    elseif HasOverrideActionBar and HasOverrideActionBar() and GetOverrideBarIndex then
        page = GetOverrideBarIndex()
    elseif HasTempShapeshiftActionBar and HasTempShapeshiftActionBar() and GetTempShapeshiftBarIndex then
        page = GetTempShapeshiftBarIndex()
    elseif page == 1 and HasBonusActionBar and HasBonusActionBar() and GetBonusBarIndex then
        page = GetBonusBarIndex()
    end
    self:SetAttribute("mainpage", page)
    self:ChildUpdate("slots", self:GetAttribute("set"))
]=]
local updateSlot = [=[
    local slot = self:GetAttribute("slot-" .. message)
    if slot then
        if slot <= 12 then
            slot = slot + (self:GetParent():GetAttribute("mainpage") - 1) * 12
        end
        self:SetAttribute("action", slot)
        self:Show()
    else
        self:SetAttribute("action", nil)
        self:Hide()
    end
]=]
local selectSet = [=[
    local hud = self:GetParent()
    local set = self:GetAttribute("select-set")
    hud:SetAttribute("set", set)
    hud:ChildUpdate("slots", set)
]=]

local function textButton(parent, title, script, template)
    local button = CreateFrame("Button", nil, parent, template or "UIPanelButtonTemplate")
    if template then
        local bg = button:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.08, 0.1, 0.14, 0.95)
        local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", 3, 0)
        label:SetPoint("RIGHT", -3, 0)
        label:SetText(title)
        button.label, button.bg = label, bg
        button:RegisterForClicks("LeftButtonUp")
    else
        button:SetText(title)
    end
    if script then button:SetScript("OnClick", script) end
    return button
end

local function command(name)
    return function()
        local fn = _G[name]
        if fn then fn() end
    end
end

local function syncTicker()
    local wanted = root and root:IsShown() and UnitExists("target") and (api.IsActionInRange or IsActionInRange)
    if wanted and not ticker and C_Timer and C_Timer.NewTicker then
        ticker = C_Timer.NewTicker(0.25, function()
            for _, button in ipairs(buttons) do
                if button:IsShown() then updateTint(button) end
            end
        end)
    elseif not wanted and ticker then
        ticker:Cancel()
        ticker = nil
    end
end

local function createHUD()
    root = CreateFrame("Frame", "SPTouchHUDFrame", UIParent, "SecureHandlerStateTemplate")
    root:SetFrameStrata("HIGH")
    root:SetClampedToScreen(true)
    root:SetAttribute("mainpage", 1)
    root:SetAttribute("set", 1)
    root:SetAttribute("_onstate-hudpage", updatePage)
    buttons, switches, utilities = {}, {}, {}
    for i = 1, maxButtons do
        local button = CreateFrame("Button", nil, root, "SecureActionButtonTemplate")
        button:RegisterForClicks("LeftButtonUp")
        button:SetAttribute("useOnKeyDown", false)
        button:SetAttribute("type", "action")
        button:SetAttribute("_childupdate-slots", updateSlot)
        local bg = button:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.13, 0.16, 0.22, 0.9)
        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetPoint("TOPLEFT", 2, -2)
        button.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        button.cooldown:SetAllPoints(button.icon)
        button.charge = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        button.charge:SetAllPoints(button.icon)
        local countOverlay = CreateFrame("Frame", nil, button)
        countOverlay:SetAllPoints()
        countOverlay:SetFrameLevel(button.charge:GetFrameLevel() + 1)
        button.count = countOverlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        button.count:SetPoint("BOTTOMRIGHT", -3, 3)
        button:HookScript("OnAttributeChanged", function(self, name)
            if name == "action" then refresh(self) end
        end)
        buttons[i] = button
    end
    for i = 1, 3 do
        local button = textButton(root, "", nil, "SecureHandlerClickTemplate")
        button:SetAttribute("select-set", i)
        button:SetAttribute("_onclick", selectSet)
        switches[i] = button
    end
    root:HookScript("OnAttributeChanged", function(_, name, value)
        if name == "set" then
            for i, button in ipairs(switches) do
                if i == value then button.bg:SetColorTexture(0.25, 0.3, 0.4, 1)
                else button.bg:SetColorTexture(0.08, 0.1, 0.14, 0.95) end
            end
        end
    end)
    local function macro(label, text)
        local button = textButton(root, label, nil, "SecureActionButtonTemplate")
        button:SetAttribute("useOnKeyDown", false)
        button:SetAttribute("type", "macro")
        button:SetAttribute("macrotext", text)
        utilities[#utilities + 1] = button
        return button
    end
    macro("Alvo", "/targetenemy")
    macro("Atacar", "/startattack")
    -- Forever's native interaction control owns interact selection and press/release.
    local interactName = "GamepadMainActionBarFramePageUnitTopCenteredAnchorTopBarActionButton5"
    local interact = macro("Interagir", "/click GamepadMainActionBarFramePageUnitTopCenteredAnchorTopBarActionButton5 LeftButton 1\n/click GamepadMainActionBarFramePageUnitTopCenteredAnchorTopBarActionButton5 LeftButton 0")
    utilities[#utilities + 1] = textButton(root, "Bolsas", command("ToggleAllBags"))
    utilities[#utilities + 1] = textButton(root, "Mapa", command("ToggleWorldMap"))
    utilities[#utilities + 1] = textButton(root, "Personagem", function()
        if ToggleCharacter then ToggleCharacter("PaperDollFrame") end
    end)
    utilities[#utilities + 1] = textButton(root, "Missões", command("ToggleQuestLog"))
    utilities[#utilities + 1] = textButton(root, "Grimório", function()
        if PlayerSpellsUtil and PlayerSpellsUtil.ToggleSpellBookFrame then PlayerSpellsUtil.ToggleSpellBookFrame() end
    end)
    utilities[#utilities + 1] = textButton(root, "Chat", function()
        if ChatFrameUtil and ChatFrameUtil.OpenChat then ChatFrameUtil.OpenChat(nil) end
    end)
    utilities[#utilities + 1] = textButton(root, "Config", function() editor:SetShown(not editor:IsShown()) end)
    root.UpdateInteract = function()
        local available = _G[interactName] ~= nil
        interact:SetAttribute("type", available and "macro" or nil)
        interact.label:SetText(available and "Interagir" or "Sem interação")
    end
    RegisterStateDriver(root, "hudpage", "[vehicleui]vehicle; [overridebar]override; [shapeshift]temp; [bar:2]2; [bar:3]3; [bar:4]4; [bar:5]5; [bar:6]6; [bonusbar:1]bonus1; [bonusbar:2]bonus2; [bonusbar:3]bonus3; [bonusbar:4]bonus4; [bonusbar:5]bonus5; 1")
end

local function applyLayout()
    if InCombatLockdown() then pending = true; return end
    pending = false
    if not root then createHUD() end
    local compiled, largest = {}, 0
    for i, set in ipairs(layout.sets) do
        local slots = parseSlots(set.text) or {}
        compiled[i] = slots
        largest = math.max(largest, math.min(layout.count, #slots))
        switches[i].label:SetText("|cff" .. set.color .. set.label .. "|r")
    end
    local columns = layout.columns
    local pitch = 44 + layout.spacing
    local actionRows = math.ceil(largest / columns)
    local utilityRows = math.ceil(#utilities / columns)
    local width, height = math.max(columns * pitch, 228), 33 + (actionRows + utilityRows) * pitch
    local scale = math.min(layout.scale, UIParent:GetWidth() / (width + 16), UIParent:GetHeight() / (height + 16))
    root:SetScale(scale)
    root:SetSize(width, height)
    root:SetAlpha(layout.opacity)
    root:ClearAllPoints()
    local x = layout.left and 1 - layout.x or layout.x
    root:SetPoint("CENTER", UIParent, "BOTTOMLEFT", UIParent:GetWidth() * x / scale, UIParent:GetHeight() * layout.y / scale)
    local function place(button, index, rowStart)
        local column = (index - 1) % columns
        if layout.left then column = columns - 1 - column end
        button:ClearAllPoints()
        button:SetSize(44, 44)
        button:SetPoint("TOPLEFT", column * pitch, -33 - (rowStart + math.floor((index - 1) / columns)) * pitch)
    end
    for i, button in ipairs(buttons) do
        place(button, i, 0)
        for set = 1, 3 do
            button:SetAttribute("slot-" .. set, i <= layout.count and compiled[set][i] or nil)
        end
    end
    for i, button in ipairs(switches) do
        button:ClearAllPoints()
        button:SetSize(73, 29)
        button:SetPoint("TOPLEFT", (layout.left and 3 - i or i - 1) * 76, 0)
    end
    for i, button in ipairs(utilities) do place(button, i, actionRows) end
    root:UpdateInteract()
    root:Execute(updatePage)
    root:SetShown(account.enabled)
    syncTicker()
end

local function createEditor()
    editor = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    editor:SetSize(510, 335)
    editor:SetPoint("CENTER")
    editor:SetFrameStrata("FULLSCREEN_DIALOG")
    editor:EnableMouse(true)
    editor:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8"})
    editor:SetBackdropColor(0.07, 0.08, 0.11, 0.97)
    editor:Hide()
    local function label(title, x, y)
        local item = editor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        item:SetPoint("TOPLEFT", x, y)
        item:SetText(title)
        return item
    end
    local function field(x, y, width, limit)
        local box = CreateFrame("EditBox", nil, editor, "InputBoxTemplate")
        box:SetSize(width, 26)
        box:SetPoint("TOPLEFT", x, y)
        box:SetAutoFocus(false)
        box:SetMaxLetters(limit)
        box:SetScript("OnEscapePressed", box.ClearFocus)
        box:SetScript("OnEnterPressed", box.ClearFocus)
        return box
    end
    local function button(title, x, y, width, click)
        local item = textButton(editor, title, click)
        item:SetSize(width, 26)
        item:SetPoint("TOPLEFT", x, y)
        return item
    end
    label("SPTouchHUD", 16, -12)
    label("Conjunto                           Cor RGB     Barras e slots", 16, -52)
    local labels, tones, lists = {}, {}, {}
    local showPicker, hidePicker
    for i = 1, 3 do
        local y = -48 - i * 30
        local index = i
        labels[i], tones[i], lists[i] = field(20, y, 118, 24), field(149, y, 62, 6), field(225, y, 153, 400)
        button("Cor", 382, y, 46, function()
            local palette = {"4bdace", "ffba60", "c9a2ff", "f98484", "99d97f", "ffffff"}
            local color = tones[index]:GetText():lower()
            for j, value in ipairs(palette) do
                if value == color then
                    tones[index]:SetText(palette[j % #palette + 1])
                    return
                end
            end
            tones[index]:SetText(palette[1])
        end)
        button("Slots", 434, y, 60, function() showPicker(index) end)
    end
    label("Escala         Opacidade     Espaço         Colunas       Limite por conjunto", 16, -176)
    local fields = {}
    for i, spec in ipairs(layoutFields) do
        local index, step = i, i <= 2 and 0.05 or 1
        local x = 19 + (index - 1) * 86
        fields[index] = field(x + 19, -198, 42, 6)
        local function adjust(direction)
            local box = fields[index]
            local value = tonumber(box:GetText()) or layout[spec[1]]
            value = bound(value + direction * step, spec[4], spec[2], spec[3])
            box:SetText(index <= 2 and string.format("%.2f", value) or tostring(value))
        end
        button("−", x - 3, -198, 19, function() adjust(-1) end)
        button("+", x + 60, -198, 19, function() adjust(1) end)
    end
    local status = label("", 16, -315)
    local mirror, enable, grip
    local function load()
        for i, set in ipairs(layout.sets) do
            labels[i]:SetText(set.label); tones[i]:SetText(set.color); lists[i]:SetText(set.text)
        end
        for i, spec in ipairs(layoutFields) do fields[i]:SetText(tostring(layout[spec[1]])) end
        mirror:SetText(layout.left and "Canhoto" or "Destro")
        enable:SetText(account.enabled and "HUD ligado" or "HUD desligado")
        grip:SetShown(not InCombatLockdown())
    end
    button("Fechar", 415, -6, 80, function() editor:Hide() end)
    button("Aplicar", 16, -231, 88, function()
        local sets = {}
        for i = 1, 3 do
            local name = cleanLabel(labels[i]:GetText(), i)
            local color, slots = tones[i]:GetText(), lists[i]:GetText()
            if not validColor(color) or not parseSlots(slots) then
                status:SetText("Confira a cor e os slots do conjunto " .. i)
                return
            end
            sets[i] = {label = name, color = color, text = slots}
        end
        layout.sets = sets
        for i, spec in ipairs(layoutFields) do
            local value = bound(fields[i]:GetText(), layout[spec[1]], spec[2], spec[3])
            layout[spec[1]] = i >= 4 and math.floor(value) or value
        end
        applyLayout()
        status:SetText(pending and "Alterações na fila até sair de combate." or "")
        load()
    end)
    mirror = button("", 112, -231, 108, function() layout.left = not layout.left; applyLayout(); load() end)
    enable = button("", 228, -231, 122, function() account.enabled = not account.enabled; applyLayout(); load() end)
    button("Restaurar padrão", 358, -231, 137, function()
        account.enabled = true
        usePreset(2)
        applyLayout()
        load()
    end)
    for i, preset in ipairs(presets) do
        local index = i
        button(preset[1], 16 + (i - 1) * 162, -269, 156, function() usePreset(index); applyLayout(); load() end)
    end

    -- This independent handle moves during the drag, then applies to the HUD on drop.
    grip = textButton(UIParent, "Arraste para posicionar HUD")
    grip:SetSize(210, 34)
    grip:SetFrameStrata("FULLSCREEN_DIALOG")
    grip:SetMovable(true)
    grip:SetClampedToScreen(true)
    grip:RegisterForDrag("LeftButton", "RightButton")
    grip:Hide()
    grip:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
    grip:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x, y = self:GetCenter()
        layout.x = bound(x / UIParent:GetWidth(), layout.x, 0, 1)
        if layout.left then layout.x = 1 - layout.x end
        layout.y = bound(y / UIParent:GetHeight(), layout.y, 0, 1)
        applyLayout()
    end)
    -- Keep the slot picker touch-operable independently of WoW's keyboard focus.
    local picker = CreateFrame("Frame", nil, editor, "BackdropTemplate")
    picker:SetAllPoints()
    picker:SetFrameLevel(editor:GetFrameLevel() + 10)
    picker:EnableMouse(true)
    picker:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8"})
    picker:SetBackdropColor(0.07, 0.08, 0.11, 1)
    picker:Hide()
    local title = picker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -16)
    local note = picker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("BOTTOMLEFT", 16, 25)
    local function pickerButton(caption, x, y, width, action)
        local item = textButton(picker, caption, action)
        item:SetSize(width, 36)
        item:SetPoint("TOPLEFT", x, y)
        return item
    end
    local currentSet, currentBar, slots
    local slotControls = {}
    local bars = {"Principal", "Inf. esq.", "Inf. dir.", "Direita", "Esquerda", "Barra 6", "Barra 7", "Barra 8"}
    local function displaySlots()
        local selected = {}
        for _, slot in ipairs(slots) do selected[slot] = true end
        local offset = (barPages[currentBar] - 1) * 12
        title:SetText("Conjunto " .. currentSet .. " · " .. bars[currentBar])
        note:SetText(#slots .. " / " .. maxButtons .. " posições selecionadas")
        for i, item in ipairs(slotControls) do
            item:SetText(selected[offset + i] and "|cff4bdace" .. i .. " ✓|r" or tostring(i))
        end
    end
    for i, name in ipairs(bars) do
        local index = i
        pickerButton(name, 16 + (i - 1) % 4 * 123, -50 - math.floor((i - 1) / 4) * 41, 110, function()
            currentBar = index
            displaySlots()
        end)
    end
    for i = 1, 12 do
        local index = i
        slotControls[i] = pickerButton(tostring(i), 16 + (i - 1) % 6 * 81, -145 - math.floor((i - 1) / 6) * 43, 68, function()
            local slot = 12 * (barPages[currentBar] - 1) + index
            for position, value in ipairs(slots) do
                if value == slot then
                    table.remove(slots, position)
                    displaySlots()
                    return
                end
            end
            if #slots < maxButtons then slots[#slots + 1] = slot end
            displaySlots()
        end)
    end
    pickerButton("Limpar conjunto", 16, -242, 130, function() slots = {}; displaySlots() end)
    pickerButton("Voltar", 269, -242, 98, function() hidePicker() end)
    pickerButton("Usar seleção", 376, -242, 118, function()
        local byPage, tokens = {}, {}
        for i, page in ipairs(barPages) do byPage[page] = i end
        for i, slot in ipairs(slots) do
            local page, index = math.ceil(slot / 12), (slot - 1) % 12 + 1
            tokens[i] = byPage[page] .. ":" .. index
        end
        lists[currentSet]:SetText(table.concat(tokens, ","))
        hidePicker()
    end)
    showPicker = function(index)
        currentSet, currentBar = index, 1
        slots = parseSlots(lists[index]:GetText()) or {}
        displaySlots()
        grip:Hide()
        picker:Show()
    end
    hidePicker = function()
        picker:Hide()
        grip:SetShown(not InCombatLockdown())
    end
    editor:SetScript("OnShow", function()
        editor:SetScale(math.min(1, UIParent:GetWidth() / 526, UIParent:GetHeight() / 388))
        grip:ClearAllPoints()
        grip:SetPoint("TOP", editor, "BOTTOM", 0, -4)
        status:SetText(pending and "Alterações na fila até sair de combate." or "")
        load()
    end)
    editor:SetScript("OnHide", function()
        picker:Hide()
        grip:StopMovingOrSizing()
        grip:Hide()
    end)
    events.CloseEditor = function() editor:Hide() end
    SLASH_SPTOUCHHUD1 = "/sphud"
    SlashCmdList.SPTOUCHHUD = function() editor:SetShown(not editor:IsShown()) end
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local panel = CreateFrame("Frame")
        local open = textButton(panel, "Editar SPTouchHUD", function()
            editor:Show()
        end)
        open:SetPoint("TOPLEFT", 20, -20)
        open:SetSize(170, 30)
        Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, "SPTouchHUD"))
    end
end

events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, arg)
    if event == "ADDON_LOADED" then
        if arg ~= addonName then
            if root and arg == "Blizzard_GamepadActionBars" then
                if InCombatLockdown() then pending = true else root:UpdateInteract() end
            end
            return
        end
        SPTouchHUDDB = type(SPTouchHUDDB) == "table" and SPTouchHUDDB or {}
        account = SPTouchHUDDB
        if account.enabled == nil then account.enabled = true end
        loadLayout()
        createEditor()
        for _, name in ipairs({
            "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "UI_SCALE_CHANGED",
            "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_UPDATE_COOLDOWN", "ACTIONBAR_UPDATE_USABLE",
            "SPELL_UPDATE_USABLE", "SPELL_UPDATE_CHARGES", "PLAYER_TARGET_CHANGED", "UPDATE_SHAPESHIFT_FORM",
        }) do events:RegisterEvent(name) end
        applyLayout()
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then events.CloseEditor(); return end
    if event == "PLAYER_ENTERING_WORLD" or event == "UI_SCALE_CHANGED" or (event == "PLAYER_REGEN_ENABLED" and pending) then
        applyLayout()
    end
    if not root or not root:IsShown() then return end
    if event == "PLAYER_TARGET_CHANGED" then syncTicker() end
    for _, button in ipairs(buttons) do
        if button:IsShown() then
            if event == "ACTIONBAR_SLOT_CHANGED" then
                if not arg or arg == 0 or button:GetAttribute("action") == arg then refresh(button) end
            elseif event == "UPDATE_SHAPESHIFT_FORM" or event == "PLAYER_ENTERING_WORLD" then
                refresh(button)
            elseif event == "ACTIONBAR_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" then
                updateCooldown(button)
            else
                updateTint(button, event ~= "PLAYER_TARGET_CHANGED")
            end
        end
    end
end)
