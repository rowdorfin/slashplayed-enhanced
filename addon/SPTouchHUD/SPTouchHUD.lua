local addonName = ...
local barPages = {1, 6, 5, 3, 4, 13, 14, 15}
local presets = {
    {"iPhone compacto", 0.87, 4, "1,2,3", "4,5,6", "7,8"},
    {"iPhone MMORPG", 1, 6, "1,2,3", "4,5,6", "7,8"},
    {"iPad touchscreen", 1.16, 8, "1,2,3", "4,5,6", "7,8"},
    {"Canhoto", 1, 6, "1,2,3", "4,5,6", "7,8"},
    {"HUD 2.0 clássico", 1, 6, "1", "2", "3,6"},
}
local arcSize = 6
local arcWidth, arcHeight = 274, 166
local layoutVersion = 5
-- Match UIKit's lane fractions (checked by addon/test/test.sh).
local joystickLane = 0.23
-- Each face has three additional units of hit area on each side.
local arc = {{139, 30, 42}, {88, 30, 42}, {74, 82, 42},
             {108, 136, 42}, {160, 136, 42}, {212, 136, 42},
             {31, 37, 29}, {220, 64, 66}, {32, 118, 29}}
local pageCell = {253, 143, 28}
local editNames = {"1", "2", "3", "4", "5", "6", "Alvo", "Principal", "Interagir"}
local border = {0.64, 0.77, 0.79}
local dark = {0.06, 0.09, 0.12}
local circleFile = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local maxButtons = 48
local lastPage = barPages[#barPages]
local layoutFields = {
    {"scale", 0.55, 1.8, 1}, {"opacity", 0.2, 1, 0.94}, {"spacing", 0, 24, 5},
    {"columns", 4, 10, 6}, {"count", 1, maxButtons, maxButtons},
}
local colors = {"4bdace", "ffba60", "c9a2ff"}
local root, buttons, switches, utilities, editor, pending, ticker
local main, compiledEntries, slotsDirty
local attackIcon = "Interface\\Icons\\Ability_MeleeDamage"
local barForPage = {}
for index, page in ipairs(barPages) do barForPage[page] = index end
local account, layout, menu, nextPage, appliedClassic, resetSelection
local stopEditing, updateView
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

local function encodeSlots(slots)
    local tokens = {}
    for i, slot in ipairs(slots) do
        tokens[i] = barForPage[math.ceil(slot / 12)] .. ":" .. ((slot - 1) % 12 + 1)
    end
    return table.concat(tokens, ",")
end

local function resetGeometry(index)
    local preset = presets[index]
    layout.version = layoutVersion
    layout.x, layout.y = 0.79, 0.39
    layout.arcX, layout.arcY, layout.positions, layout.buttonOpacity = 1, 0, {}, {}
    layout.scale, layout.opacity, layout.spacing, layout.columns = preset[2], 0.94, 5, preset[3]
end

local function usePreset(index)
    local preset = presets[index]
    layout = {count = maxButtons, left = index == 4, classic = index == 5,
        hideEmpty = index ~= 5, auxiliaries = true, sets = {}}
    resetGeometry(index)
    for i = 1, 3 do
        layout.sets[i] = {label = "Conjunto " .. i, color = colors[i], text = preset[3 + i]}
    end
    SPTouchHUDCharDB = layout
    resetSelection = true
end

local function collides(cell, other)
    local distance = (cell[3] + other[3]) / 2 + 6
    return math.abs(cell[1] - other[1]) < distance and math.abs(cell[2] - other[2]) < distance
end

local function fits(index, cell)
    local x, y, size = unpack(cell)
    local radius = size / 2 + 3
    if x < radius or x + radius > arcWidth or y < radius or y + radius > arcHeight then return false end
    for i, default in ipairs(arc) do
        if i ~= index and collides(cell, layout.positions[i] or default) then return false end
    end
    return not collides(cell, pageCell)
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
    if type(layout) ~= "table" then
        usePreset(2)
        return
    end
    if layout.version ~= layoutVersion then
        local scale, opacity = layout.scale, layout.opacity
        resetGeometry(layout.classic and 5 or 2)
        layout.scale, layout.opacity = scale, opacity
    end
    local mainSlot = tonumber(layout.mainSlot)
    if not mainSlot or mainSlot % 1 ~= 0 or not barForPage[math.ceil(mainSlot / 12)] then
        layout.mainSlot = nil
    else
        layout.mainSlot = mainSlot
    end
    local opacity = type(layout.buttonOpacity) == "table" and layout.buttonOpacity or {}
    layout.buttonOpacity = {}
    for i = 1, #arc do
        layout.buttonOpacity[i] = bound(opacity[i], 1, 0.25, 1)
    end
    local saved = layout.positions
    layout.positions = {}
    if type(saved) == "table" then
        -- Cells can trade places. Validate the combined layout before accepting it.
        for i, default in ipairs(arc) do
            local cell = saved[i]
            if type(cell) == "table" then
                layout.positions[i] = {bound(cell[1], default[1], 0, arcWidth),
                    bound(cell[2], default[2], 0, arcHeight), bound(cell[3], default[3], 28, 92)}
            end
        end
        for i, cell in pairs(layout.positions) do
            if not fits(i, cell) then layout.positions = {}; break end
        end
    end
    if type(layout.sets) ~= "table" then layout.sets = {} end
    layout.x, layout.y = bound(layout.x, 0.79, 0, 1), bound(layout.y, 0.39, 0, 1)
    layout.left = layout.left == true
    layout.classic = layout.classic == true
    layout.arcX = bound(layout.arcX, 1, 0, 1)
    layout.arcY = bound(layout.arcY, 0, 0, 1)
    layout.hideEmpty = not layout.classic or layout.hideEmpty == true
    layout.auxiliaries = layout.auxiliaries ~= false
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
    local icon = slot and texture and texture(slot)
    if not readable(icon) then icon = nil end
    if not slot and button == main then icon = attackIcon end
    button.icon:SetTexture(icon or nil)
    if button == main then
        button.emptyIcon:SetShown(slot ~= nil and not icon)
    end
    updateCooldown(button)
    updateTint(button, true)
end

-- The restricted environment exposes the page APIs as globals. Occupancy is
-- compiled in ordinary Lua and installed as numeric secure attributes.
local updatePage = [=[
    local page = GetActionBarPage and GetActionBarPage() or tonumber(newstate) or 1
    local positional
    if HasVehicleActionBar and HasVehicleActionBar() and GetVehicleBarIndex then
        page, positional = GetVehicleBarIndex(), true
    elseif HasOverrideActionBar and HasOverrideActionBar() and GetOverrideBarIndex then
        page, positional = GetOverrideBarIndex(), true
    elseif HasTempShapeshiftActionBar and HasTempShapeshiftActionBar() and GetTempShapeshiftBarIndex then
        page, positional = GetTempShapeshiftBarIndex(), true
    elseif page == 1 and HasBonusActionBar and HasBonusActionBar() and GetBonusBarIndex then
        page = GetBonusBarIndex()
    end
    local bank = not positional and self:GetAttribute("compiled-" .. page) and page or 0
    local set = self:GetAttribute("set")
    local group = (set - 1) % 3 + 1
    local pages = self:GetAttribute("pages-" .. bank .. "-" .. group)
    if not pages then return end
    self:SetAttribute("mainpage", page)
    self:SetAttribute("bank", bank)
    if set >= group + pages * 3 then
        set = group
        self:SetAttribute("set", set)
    end
    self:ChildUpdate("slots", set)
]=]
local updateSlot = [=[
    local hud = self:GetParent()
    local bank = hud:GetAttribute("bank")
    local slot = self:GetAttribute("slot-" .. bank .. "-" .. message)
    if bank == 0 and slot and slot <= 12 then
        slot = slot + (hud:GetAttribute("mainpage") - 1) * 12
    end
    if slot ~= self:GetAttribute("action") then self:SetAttribute("action", slot) end
    if slot then self:Show() else self:Hide() end
]=]
local updateMain = [=[
    local slot = self:GetAttribute("main-slot")
    local page = self:GetParent():GetAttribute("mainpage")
    if slot and slot <= 12 then slot = slot + (page - 1) * 12 end
    self:SetAttribute("type", slot and "action" or "macro")
    if slot ~= self:GetAttribute("action") then self:SetAttribute("action", slot) end
]=]
local selectSet = [=[
    local hud = self:GetParent()
    local set = self:GetAttribute("select-set")
    hud:SetAttribute("set", set)
    hud:ChildUpdate("slots", set)
]=]

local cyclePage = [=[
    local hud = self:GetParent()
    local active = hud:GetAttribute("set")
    local group = (active - 1) % 3 + 1
    local prefix = "pages-" .. hud:GetAttribute("bank") .. "-"
    local pages = hud:GetAttribute(prefix .. group)
    local set = active + 3
    if set >= group + pages * 3 then
        set = group
        for i = 1, 3 do
            set = set % 3 + 1
            if hud:GetAttribute("used-" .. hud:GetAttribute("bank") .. "-" .. set) then break end
        end
        if not hud:GetAttribute("used-" .. hud:GetAttribute("bank") .. "-" .. set) then set = group end
    end
    hud:SetAttribute("set", set)
    hud:ChildUpdate("slots", set)
]=]

local function circle(frame, texture)
    if not frame.CreateMaskTexture then return end
    local mask = frame:CreateMaskTexture()
    mask:SetAllPoints(texture)
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("CircleMask") then
        mask:SetAtlas("CircleMask")
    else
        mask:SetTexture(circleFile, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    end
    texture:AddMaskTexture(mask)
    frame.masks = frame.masks or {}
    frame.masks[#frame.masks + 1] = {texture, mask}
end

local function setCircular(button, round)
    if button.round == round then return end
    -- Textures are created circular. Restore their masks only after leaving classic.
    if button.round ~= nil or not round then
        for _, pair in ipairs(button.masks or {}) do
            if round then pair[1]:AddMaskTexture(pair[2]) else pair[1]:RemoveMaskTexture(pair[2]) end
        end
    end
    button.round = round
end

local function styleAction(button, round)
    local changed = button.round ~= round
    setCircular(button, round)
    if not changed then return end
    local atlas = round and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("CircleMask")
    for _, cooldown in ipairs({button.cooldown, button.charge}) do
        if cooldown.SetSwipeTexture and cooldown.SetTexCoordRange then
            local file = atlas and (atlas.file or atlas.filename) or (round and circleFile or nil)
            cooldown:SetSwipeTexture(file, 0, 0, 0, 0.64)
            cooldown:SetTexCoordRange(
                {x = atlas and atlas.leftTexCoord or 0, y = atlas and atlas.topTexCoord or 0},
                {x = atlas and atlas.rightTexCoord or 1, y = atlas and atlas.bottomTexCoord or 1})
        end
    end
end

local function face(button)
    local rim = button:CreateTexture(nil, "BACKGROUND", nil, 0)
    rim:SetPoint("TOPLEFT", 3, -3)
    rim:SetPoint("BOTTOMRIGHT", -3, 3)
    rim:SetColorTexture(border[1], border[2], border[3], 0.66)
    circle(button, rim)
    local bg = button:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetPoint("TOPLEFT", 4, -4)
    bg:SetPoint("BOTTOMRIGHT", -4, 4)
    bg:SetColorTexture(dark[1], dark[2], dark[3], 0.82)
    circle(button, bg)
    local pressed = button:CreateTexture(nil, "HIGHLIGHT")
    pressed:SetAllPoints(bg)
    pressed:SetColorTexture(border[1], border[2], border[3], 0.18)
    circle(button, pressed)
    if button.SetPushedTexture then
        local pushed = button:CreateTexture(nil, "OVERLAY")
        pushed:SetAllPoints(bg)
        pushed:SetColorTexture(border[1], border[2], border[3], 0.40)
        circle(button, pushed)
        button:SetPushedTexture(pushed)
    end
    return bg
end

local function textButton(parent, title, script, template)
    local button = CreateFrame("Button", nil, parent, template or "UIPanelButtonTemplate")
    if template then
        local bg = face(button)
        local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetTextColor(border[1], border[2], border[3])
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
    local function actionButton()
        local button = CreateFrame("Button", nil, root, "SecureActionButtonTemplate")
        button:RegisterForClicks("LeftButtonUp")
        button:SetAttribute("useOnKeyDown", false)
        button:SetAttribute("type", "action")
        button:SetAttribute("_childupdate-slots", updateSlot)
        face(button)
        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetPoint("TOPLEFT", 5, -5)
        button.icon:SetPoint("BOTTOMRIGHT", -5, 5)
        circle(button, button.icon)
        button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        button.cooldown:SetAllPoints(button.icon)
        button.charge = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        button.charge:SetAllPoints(button.icon)
        local countOverlay = CreateFrame("Frame", nil, button)
        countOverlay:SetAllPoints()
        countOverlay:SetFrameLevel(button.charge:GetFrameLevel() + 1)
        button.count = countOverlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        button.count:SetPoint("BOTTOMRIGHT", -9, 7)
        button:HookScript("OnAttributeChanged", function(self, name)
            if name == "action" then refresh(self) end
        end)
        return button
    end
    for i = 1, maxButtons do buttons[i] = actionButton() end
    main = actionButton()
    main:SetAttribute("_childupdate-slots", updateMain)
    main:SetAttribute("macrotext", "/startattack")
    main.emptyIcon = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    main.emptyIcon:SetPoint("CENTER")
    main.emptyIcon:SetText("—")
    refresh(main)
    buttons[maxButtons + 1] = main
    for i = 1, 3 do
        local button = textButton(root, "", nil, "SecureHandlerClickTemplate")
        button:SetAttribute("select-set", i)
        button:SetAttribute("_onclick", selectSet)
        switches[i] = button
    end
    nextPage = textButton(root, "", nil, "SecureHandlerClickTemplate")
    nextPage:SetAttribute("_onclick", cyclePage)
    updateView = function()
        local active = root:GetAttribute("set")
        local group = (active - 1) % 3 + 1
        for i, button in ipairs(switches) do
            if i == group then button.bg:SetColorTexture(0.22, 0.33, 0.36, 1)
            else button.bg:SetColorTexture(dark[1], dark[2], dark[3], 0.82) end
        end
        local bank = root:GetAttribute("bank") or 0
        local total, before = 0, 0
        for i = 1, 3 do
            local pages = root:GetAttribute("pages-" .. bank .. "-" .. i) or 1
            if i == group or root:GetAttribute("used-" .. bank .. "-" .. i) then
                total = total + pages
                if i < group then before = before + pages end
            end
        end
        nextPage.label:SetText(before + math.floor((active - group) / 3) + 1 .. "/" .. total)
    end
    root:HookScript("OnAttributeChanged", function(_, name)
        if name == "set" or name == "bank" then updateView() end
    end)
    local function macro(label, text)
        local button = textButton(root, label, nil, "SecureActionButtonTemplate")
        button:SetAttribute("useOnKeyDown", false)
        button:SetAttribute("type", "macro")
        button:SetAttribute("macrotext", text)
        utilities[#utilities + 1] = button
        return button
    end
    local function glyph(button, atlasName, fallback)
        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetSize(15, 15)
        icon:SetPoint("CENTER")
        if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlasName) then
            icon:SetAtlas(atlasName)
        else
            icon:SetTexture(fallback)
        end
        return icon
    end
    local target = macro("", "/targetenemy")
    glyph(target, "gamepad-targeting-hostile", "Interface\\CURSOR\\Attack")
    utilities[2] = main
    -- Forever's native interaction control owns interact selection and press/release.
    local interactName = "GamepadMainActionBarFramePageUnitTopCenteredAnchorTopBarActionButton5"
    local interact = macro("", "/click GamepadMainActionBarFramePageUnitTopCenteredAnchorTopBarActionButton5 LeftButton 1\n/click GamepadMainActionBarFramePageUnitTopCenteredAnchorTopBarActionButton5 LeftButton 0")
    local interactIcon = glyph(interact, "crosshair_interact_32", "Interface\\CURSOR\\Speak")
    local utilityParent = CreateFrame("Frame", nil, UIParent)
    utilityParent:SetFrameStrata("HIGH")
    utilityParent:SetSize(182, 44)
    menu = textButton(utilityParent, "⚙", nil, "BackdropTemplate")
    menu:SetSize(28, 28)
    menu:SetPoint("CENTER", utilityParent, "CENTER")
    local panel = CreateFrame("Frame", nil, utilityParent)
    panel:SetSize(176, layout.auxiliaries and 162 or 40)
    panel:SetPoint("TOP", menu, "BOTTOM", 0, -3)
    panel:Hide()
    menu:SetScript("OnClick", function() panel:SetShown(not panel:IsShown()) end)
    utilityParent:SetScript("OnHide", function() panel:Hide() end)
    local function utility(label, action)
        local button = textButton(panel, label, function()
            if not appliedClassic then panel:Hide() end
            action()
        end, "BackdropTemplate")
        button:SetSize(82, 36)
        utilities[#utilities + 1] = button
        return button
    end
    utility("Editar HUD", function() editor:SetShown(not editor:IsShown()) end)
    utility("Bolsas", command("ToggleAllBags"))
    utility("Mapa", command("ToggleWorldMap"))
    utility("Personagem", function() if ToggleCharacter then ToggleCharacter("PaperDollFrame") end end)
    utility("Missões", command("ToggleQuestLog"))
    utility("Grimório", function()
        if PlayerSpellsUtil and PlayerSpellsUtil.ToggleSpellBookFrame then PlayerSpellsUtil.ToggleSpellBookFrame() end
    end)
    utility("Chat", function() if ChatFrameUtil and ChatFrameUtil.OpenChat then ChatFrameUtil.OpenChat(nil) end end)
    utility("Opções", command("ToggleGameMenu"))
    menu.panel = panel
    root.UpdateInteract = function()
        local available = _G[interactName] ~= nil
        interact:SetAttribute("type", available and "macro" or nil)
        local tint = available and 1 or 0.42
        interactIcon:SetVertexColor(tint, tint, tint)
    end
    RegisterStateDriver(root, "hudpage", "[vehicleui]vehicle; [overridebar]override; [shapeshift]temp; [bar:2]2; [bar:3]3; [bar:4]4; [bar:5]5; [bar:6]6; [bonusbar:1]bonus1; [bonusbar:2]bonus2; [bonusbar:3]bonus3; [bonusbar:4]bonus4; [bonusbar:5]bonus5; 1")
end

local function placeArcMenu(scale)
    local host, panel = menu:GetParent(), menu.panel
    host:ClearAllPoints()
    host:SetScale(scale)
    host:SetAlpha(layout.opacity)
    host:SetPoint("CENTER", UIParent, "TOP", 0, -UIParent:GetHeight() * 0.09 / scale)
    host:SetSize(28, 28)
    panel:SetSize(176, layout.auxiliaries and 162 or 40)
    panel:ClearAllPoints()
    panel:SetPoint("TOP", menu, "BOTTOM", 0, -3)
    for i = 4, #utilities do
        local button, index = utilities[i], i - 4
        button:ClearAllPoints()
        button:SetSize(82, 36)
        button:SetPoint("TOPLEFT", panel, "TOPLEFT", index % 2 * 90, -math.floor(index / 2) * 39)
        setCircular(button, true)
        button:SetShown(i == 4 or layout.auxiliaries)
    end
    menu:Show()
    panel:Hide()
    host:SetShown(account.enabled)
end

local function placeClassic(largest)
    local columns = layout.columns
    local pitch = 44 + layout.spacing
    local actionRows = math.ceil(largest / columns)
    local utilityRows = math.ceil(#utilities / columns)
    local width, height = math.max(columns * pitch, 228), 33 + (actionRows + utilityRows) * pitch
    local classicWidth = 1 - 2 * joystickLane
    local scale = math.min(layout.scale, UIParent:GetWidth() * classicWidth / width, UIParent:GetHeight() * 0.72 / height)
    root:SetScale(scale)
    root:SetSize(width, height)
    root:ClearAllPoints()
    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    local x = bound(layout.left and 1 - layout.x or layout.x, 0.5, joystickLane + width * scale / (2 * w), 1 - joystickLane - width * scale / (2 * w))
    local y = bound(layout.y, 0.45, 0.08 + height * scale / (2 * h), 0.80 - height * scale / (2 * h))
    root:SetPoint("CENTER", UIParent, "BOTTOMLEFT", w * x / scale, h * y / scale)
    local function place(button, index, rowStart, anchor)
        local column = (index - 1) % columns
        if layout.left then column = columns - 1 - column end
        button:ClearAllPoints()
        button:SetSize(44, 44)
        button:SetPoint("TOPLEFT", anchor or root, "TOPLEFT", column * pitch, -33 - (rowStart + math.floor((index - 1) / columns)) * pitch)
    end
    for i, button in ipairs(buttons) do
        if i <= largest then place(button, i, 0) end
        styleAction(button, false)
    end
    for i, button in ipairs(switches) do
        button:ClearAllPoints()
        button:SetSize(73, 29)
        button:SetPoint("TOPLEFT", (layout.left and 3 - i or i - 1) * 76, 0)
        setCircular(button, false)
    end
    local host, panel = menu:GetParent(), menu.panel
    host:ClearAllPoints()
    host:SetScale(scale)
    host:SetAlpha(layout.opacity)
    host:SetPoint("TOPLEFT", root, "TOPLEFT")
    host:SetSize(width, height)
    panel:SetSize(width, height)
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", host, "TOPLEFT")
    for i, button in ipairs(utilities) do
        place(button, i, actionRows, i > 3 and panel or root)
        if i > 3 then button:Show() end
        setCircular(button, false)
    end
    menu:Hide()
    host:SetShown(account.enabled and layout.auxiliaries)
    panel:SetShown(host:IsShown())
end

local function pointScale(width, height)
    return height / (width / height < 1.65 and 768 or 390)
end

local function arcSpace(w, h)
    local point = pointScale(w, h)
    -- The shim caps Jump's lane at 21% of the game height plus eight points.
    -- The side margin covers the remaining landscape inset after the game crop.
    local left = w * joystickLane
    local right = w - math.max(w * 0.06, 48 * point)
    local bottom = h * 0.21 + math.max(8, 8 * point)
    return left, bottom, right - left, h * 0.84 - bottom
end

local function placeArc()
    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    if w <= 0 or h <= 0 then return end
    local left, bottom, width, height = arcSpace(w, h)
    local scale = math.min(layout.scale * pointScale(w, h), width / arcWidth, height / arcHeight)
    root:SetScale(scale)
    root:SetSize(arcWidth, arcHeight)
    root:ClearAllPoints()
    local x = left + (width - arcWidth * scale) * layout.arcX
    local y = bottom + (height - arcHeight * scale) * layout.arcY
    if layout.left then x = w - x - arcWidth * scale end
    root:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    local function place(button, cell)
        local x, y, size = unpack(cell)
        button:ClearAllPoints()
        button:SetSize(size + 6, size + 6)
        button:SetPoint("CENTER", root, "BOTTOMLEFT", layout.left and arcWidth - x or x, y)
    end
    for i, cell in ipairs(arc) do
        local button = i <= arcSize and buttons[i] or utilities[i - arcSize]
        place(button, layout.positions[i] or cell)
        button:SetAlpha(layout.buttonOpacity[i] or 1)
        if i <= arcSize or button == main then styleAction(button, true) else setCircular(button, true) end
    end
    place(nextPage, pageCell)
    placeArcMenu(math.min(pointScale(w, h), w / 320, h / 400))
end

local function compileSlots()
    local lists, occupied, largest = {}, {}, 0
    compiledEntries = {}
    main:SetAttribute("main-slot", layout.mainSlot)
    local hasAction = api.HasAction or HasAction
    for i, set in ipairs(layout.sets) do lists[i] = parseSlots(set.text) end
    local function include(slot)
        if not layout.hideEmpty then return true end
        if occupied[slot] == nil then
            local value = hasAction and hasAction(slot)
            occupied[slot] = not readable(value) or value ~= false
        end
        return occupied[slot]
    end
    local pageSize = layout.classic and maxButtons or arcSize
    local limit = layout.classic and layout.count or maxButtons
    local maxPages = maxButtons / pageSize
    for bank = 0, lastPage do
        for group, list in ipairs(lists) do
            local compact, source = {}, {}
            compiledEntries[bank * 3 + group] = source
            for i = 1, math.min(#list, limit) do
                local slot = list[i]
                local main = slot <= 12
                if main then slot = slot + math.max(0, bank - 1) * 12 end
                if (main and bank == 0) or include(slot) then
                    compact[#compact + 1], source[#source + 1] = slot, i
                end
            end
            largest = math.max(largest, #compact)
            root:SetAttribute("used-" .. bank .. "-" .. group, #compact > 0)
            root:SetAttribute("pages-" .. bank .. "-" .. group, math.max(1, math.ceil(#compact / pageSize)))
            for page = 0, maxPages - 1 do
                local key = "slot-" .. bank .. "-" .. (group + page * 3)
                for i = 1, page == 0 and maxButtons or arcSize do
                    local slot = i <= pageSize and compact[page * pageSize + i] or nil
                    local button = buttons[i]
                    if button:GetAttribute(key) ~= slot then button:SetAttribute(key, slot) end
                end
            end
        end
        if bank ~= 0 then root:SetAttribute("compiled-" .. bank, true) end
    end
    if resetSelection then
        resetSelection = nil
        root:SetAttribute("set", 1)
    end
    root:Execute(updatePage)
    updateView()
    return largest
end

local function applyLayout()
    if InCombatLockdown() then pending = true; return end
    pending, slotsDirty = false, nil
    if not root then createHUD() end
    local largest = compileSlots()
    for i, set in ipairs(layout.sets) do
        local label = layout.classic and set.label or tostring(i)
        switches[i].label:SetText("|cff" .. set.color .. label .. "|r")
        switches[i]:SetShown(layout.classic)
    end
    for _, button in ipairs(buttons) do button:SetAlpha(1) end
    for i = 1, 3 do utilities[i]:SetAlpha(1) end
    root:SetAlpha(layout.opacity)
    if layout.classic then placeClassic(largest) else placeArc() end
    appliedClassic = layout.classic
    nextPage:SetShown(not layout.classic)
    for i = 1, 3 do utilities[i]:SetShown(i == 2 or layout.auxiliaries) end
    root:UpdateInteract()
    root:SetShown(account.enabled)
    syncTicker()
end

local function createPositionEditor(reopen, chooseAction)
    -- Independent preview targets intercept input so editing cannot cast an action.
    local overlay = CreateFrame("Frame", nil, UIParent)
    overlay:SetAllPoints(UIParent)
    overlay:SetFrameStrata("FULLSCREEN_DIALOG")
    overlay:Hide()
    local canvas = CreateFrame("Button", nil, overlay)
    canvas:SetAllPoints()
    canvas:RegisterForClicks("LeftButtonUp")
    local toolbar = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
    toolbar:SetSize(438, 64)
    toolbar:SetPoint("BOTTOM", 0, UIParent:GetHeight() * 0.065)
    toolbar:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8"})
    toolbar:SetBackdropColor(0.07, 0.08, 0.11, 0.97)
    toolbar:EnableMouse(true)
    local status = toolbar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    status:SetPoint("TOP", 0, -7)
    local selected, moving, selectingAction
    local proxies = {}
    local function position()
        local scale = root:GetScale()
        local left, bottom = root:GetLeft() * scale, root:GetBottom() * scale
        for i, proxy in ipairs(proxies) do
            local x, y, size = unpack(layout.positions[i] or arc[i])
            proxy:ClearAllPoints()
            proxy:SetSize((size + 6) * scale, (size + 6) * scale)
            proxy:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
                left + (layout.left and arcWidth - x or x) * scale, bottom + y * scale)
            local action = i == 8 and main or buttons[i]
            local texture = (i == 8 or i <= arcSize) and action.icon:GetTexture()
            proxy.icon:SetTexture(texture or nil)
        end
    end
    local function select(index)
        selected = index
        status:SetText(editNames[index] .. (selectingAction and " · toque para escolher" or " · arraste ou toque no destino"))
    end
    local function save(x, y, size)
        if InCombatLockdown() or selectingAction then return end
        local cell = {x, y, size}
        if fits(selected, cell) then
            layout.positions[selected] = cell
            placeArc()
            select(selected)
        else
            status:SetText("Espaço insuficiente para " .. editNames[selected])
        end
        position()
    end
    local function move(x, y)
        local scale = root:GetScale()
        x, y = x / scale - root:GetLeft(), y / scale - root:GetBottom()
        if layout.left then x = arcWidth - x end
        save(x, y, (layout.positions[selected] or arc[selected])[3])
    end
    canvas:SetScript("OnClick", function()
        if selectingAction then return end
        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        move(x / scale, y / scale)
    end)
    for i, name in ipairs(editNames) do
        local index = i
        local proxy = textButton(overlay, name, function()
            select(index)
            if selectingAction and (index <= arcSize or index == 8) then chooseAction(index) end
        end)
        proxy.icon = proxy:CreateTexture(nil, "ARTWORK")
        proxy.icon:SetSize(20, 20)
        proxy.icon:SetPoint("TOPLEFT", 4, -4)
        proxy:SetMovable(true)
        -- UIKit emulates a right drag for one-finger movement. Taps can also place a button.
        proxy:RegisterForDrag("LeftButton", "RightButton")
        proxy:SetScript("OnDragStart", function(self)
            if InCombatLockdown() or selectingAction then return end
            select(index)
            moving = self
            self:StartMoving()
        end)
        proxy:SetScript("OnDragStop", function(self)
            if moving ~= self then return end
            self:StopMovingOrSizing()
            local x, y = self:GetCenter()
            moving = nil
            if x and y then move(x, y) else position() end
        end)
        proxies[i] = proxy
    end
    local function toolbarButton(title, x, width, click)
        local item = textButton(toolbar, title, click)
        item:SetPoint("BOTTOMLEFT", x, 4)
        item:SetSize(width, 32)
    end
    local function resize(delta)
        local x, y, size = unpack(layout.positions[selected] or arc[selected])
        save(x, y, bound(size + delta, size, 28, 92))
    end
    toolbarButton("Menor", 4, 69, function() resize(-4) end)
    toolbarButton("Maior", 75, 69, function() resize(4) end)
    toolbarButton("Restaurar botões", 146, 116, function()
        if InCombatLockdown() then return end
        layout.positions, layout.buttonOpacity = {}, {}
        placeArc()
        position()
        select(selected)
    end)
    stopEditing = function()
        if moving then moving:StopMovingOrSizing(); moving = nil end
        overlay:Hide()
    end
    toolbarButton("Opacidade", 264, 92, function()
        if InCombatLockdown() or selectingAction then return end
        local opacity = (layout.buttonOpacity[selected] or 1) - 0.15
        layout.buttonOpacity[selected] = opacity < 0.3 and 1 or opacity
        placeArc()
        status:SetText(editNames[selected] .. " · " .. math.floor(layout.buttonOpacity[selected] * 100 + 0.5) .. "%")
    end)
    toolbarButton("Voltar", 358, 74, function() stopEditing(); reopen() end)
    return function(choose)
        selectingAction = choose == true
        if InCombatLockdown() or not root or layout.classic then return end
        editor:Hide()
        toolbar:SetScale(math.min(1, UIParent:GetWidth() / 445))
        select(1)
        position()
        overlay:Show()
    end
end

local function actionDetails(slot)
    local texture = api.GetActionTexture or GetActionTexture
    local icon = texture and texture(slot)
    local info = api.GetActionInfo or GetActionInfo
    local kind, id, name
    if info then kind, id = info(slot) end
    if readable(kind) and readable(id) and id then
        if kind == "spell" and C_Spell and C_Spell.GetSpellName then name = C_Spell.GetSpellName(id)
        elseif kind == "macro" and GetMacroInfo then name = GetMacroInfo(id)
        elseif kind == "item" and C_Item and C_Item.GetItemNameByID then name = C_Item.GetItemNameByID(id)
        elseif kind == "equipmentset" and C_EquipmentSet and C_EquipmentSet.GetEquipmentSetInfo then
            name = C_EquipmentSet.GetEquipmentSetInfo(id)
        end
    end
    if not readable(icon) then icon = nil end
    return icon, readable(name) and name or nil
end

local function createEditor()
    editor = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    editor:SetSize(510, 360)
    editor:SetPoint("CENTER", UIParent, "CENTER", 0, 8)
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
    local showPicker, hidePicker, showActionPicker
    local editPositions = createPositionEditor(function() editor:Show() end, function(index)
        editor:Show()
        showActionPicker(index)
    end)
    local editActions = button("Escolher ações", 142, -6, 137, function() editPositions(true) end)
    local editButtons = button("Mover botões", 286, -6, 120, function() editPositions(false) end)
    label("SPTouchHUD 5.0", 16, -12)
    local advanced = {label("Conjunto                           Cor RGB     Barras e slots", 16, -52)}
    local advancedShown = false
    local function toggleAdvanced(value)
        advancedShown = value
        for _, item in ipairs(advanced) do item:SetShown(value) end
    end
    button("Avançado", 16, -36, 90, function() toggleAdvanced(not advancedShown) end)
    advanced[1]:SetPoint("TOPLEFT", 16, -66)
    local labels, tones, lists = {}, {}, {}
    for i = 1, 3 do
        local y = -62 - i * 30
        local index = i
        labels[i], tones[i], lists[i] = field(20, y, 118, 24), field(149, y, 62, 6), field(225, y, 153, 400)
        for _, item in ipairs({labels[i], tones[i], lists[i]}) do advanced[#advanced + 1] = item end
        advanced[#advanced + 1] = button("Cor", 382, y, 46, function()
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
        advanced[#advanced + 1] = button("Slots", 434, y, 60, function() showPicker(index) end)
    end
    local headings = {"Escala", "Opacidade", "Espaço", "Colunas", "Slots por conjunto"}
    local order = {0, 1, 3, 4, 2}
    local fields, classicFields = {}, {}
    for i, spec in ipairs(layoutFields) do
        local index, step = i, i <= 2 and 0.05 or 1
        local x = 19 + order[index] * 95
        local heading = label(headings[index], x - 3, -176)
        fields[index] = field(x + 19, -198, 42, 6)
        local function adjust(direction)
            local box = fields[index]
            local value = tonumber(box:GetText()) or layout[spec[1]]
            value = bound(value + direction * step, spec[4], spec[2], spec[3])
            box:SetText(index <= 2 and string.format("%.2f", value) or tostring(value))
        end
        local minus = button("−", x - 3, -198, 19, function() adjust(-1) end)
        local plus = button("+", x + 60, -198, 19, function() adjust(1) end)
        if index >= 3 then
            classicFields[#classicFields + 1] = {heading, fields[index], minus, plus}
        end
    end
    local status = label("", 16, -336)
    local mirror, enable, grip, empty, aux
    local dragX, dragY
    local function load()
        for i, set in ipairs(layout.sets) do
            labels[i]:SetText(set.label); tones[i]:SetText(set.color); lists[i]:SetText(set.text)
        end
        for i, spec in ipairs(layoutFields) do fields[i]:SetText(tostring(layout[spec[1]])) end
        for _, controls in ipairs(classicFields) do
            for _, control in ipairs(controls) do control:SetShown(layout.classic) end
        end
        mirror:SetText(layout.left and "Canhoto" or "Destro")
        enable:SetText(account.enabled and "HUD ligado" or "HUD desligado")
        empty:SetText(layout.hideEmpty and "Ocultar ✓" or "Ocultar vazios")
        empty:SetShown(layout.classic)
        aux:SetText(layout.auxiliaries and "Auxiliares ✓" or "Auxiliares")
        grip:SetShown(not InCombatLockdown())
        editButtons:SetShown(not layout.classic and not InCombatLockdown())
        editActions:SetShown(not layout.classic and not InCombatLockdown())
        toggleAdvanced(advancedShown)
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
        layout.left, layout.classic, layout.hideEmpty = false, false, true
        layout.auxiliaries = true
        resetGeometry(2)
        applyLayout()
        load()
    end)
    for i, preset in ipairs(presets) do
        local index = i
        button(preset[1], 16 + (i - 1) % 3 * 162, -264 - math.floor((i - 1) / 3) * 30, 156,
            function()
                layout.left, layout.classic = index == 4, index == 5
                layout.hideEmpty = not layout.classic
                resetGeometry(index)
                applyLayout()
                load()
            end)
    end
    aux = button("", 340, -294, 78, function() layout.auxiliaries = not layout.auxiliaries; applyLayout(); load() end)
    empty = button("", 420, -294, 78, function() layout.hideEmpty = not layout.hideEmpty; applyLayout(); load() end)

    -- This independent handle moves during the drag, then applies to the HUD on drop.
    grip = textButton(UIParent, "Arraste para posicionar HUD")
    grip:SetSize(210, 34)
    grip:SetFrameStrata("FULLSCREEN_DIALOG")
    grip:SetMovable(true)
    grip:SetClampedToScreen(true)
    grip:RegisterForDrag("LeftButton", "RightButton")
    grip:Hide()
    grip:SetScript("OnDragStart", function(self)
        if InCombatLockdown() then return end
        dragX, dragY = self:GetCenter()
        self:StartMoving()
    end)
    grip:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x, y = self:GetCenter()
        if not x or not y or not dragX or not dragY or InCombatLockdown() or not root then return end
        local centerX, centerY = root:GetCenter()
        local scale = root:GetScale()
        x, y = centerX * scale + x - dragX, centerY * scale + y - dragY
        dragX, dragY = nil, nil
        local w, h = UIParent:GetWidth(), UIParent:GetHeight()
        if layout.left then x = w - x end
        if layout.classic then
            layout.x, layout.y = bound(x / w, layout.x, 0, 1), bound(y / h, layout.y, 0, 1)
        else
            local width, height = arcWidth * scale, arcHeight * scale
            local left, bottom, roomX, roomY = arcSpace(w, h)
            layout.arcX = bound((x - width / 2 - left) / math.max(1, roomX - width), 1, 0, 1)
            layout.arcY = bound((y - height / 2 - bottom) / math.max(1, roomY - height), 0, 0, 1)
        end
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
    local currentSet, currentBar, slots, selectedButton, entry, currentSlot
    local visibleEntries, visiblePosition
    local slotControls, earlier, later, clear, confirm = {}
    local bars = {"Principal", "Inf. esq.", "Inf. dir.", "Direita", "Esquerda", "Barra 6", "Barra 7", "Barra 8"}
    local function displaySlots()
        local selected = {}
        for _, slot in ipairs(slots) do selected[slot] = true end
        local offset = (barPages[currentBar] - 1) * 12
        local caption = selectedButton and editNames[selectedButton] or layout.sets[currentSet].label
        title:SetText(caption .. " · " .. bars[currentBar])
        note:SetText(selectedButton and "As posições vazias da barra principal acompanham a postura." or
            #slots .. " / " .. maxButtons .. " posições selecionadas")
        for i, item in ipairs(slotControls) do
            local slot = offset + i
            local displayed = currentBar == 1 and slot + (root:GetAttribute("mainpage") - 1) * 12 or slot
            local icon, actionName = actionDetails(displayed)
            item.icon:SetTexture(icon)
            local mark = ((selectedButton and slot == currentSlot) or (not selectedButton and selected[slot])) and "✓ " or ""
            item.name:SetText(mark .. (actionName or (icon and ("Ação " .. i) or ("Vazio " .. i))))
        end
    end
    for i, name in ipairs(bars) do
        local index = i
        pickerButton(name, 16 + (i - 1) % 4 * 123, -44 - math.floor((i - 1) / 4) * 38, 110, function()
            currentBar = index
            displaySlots()
        end)
    end
    local function commitAction()
        if selectedButton ~= 8 then layout.sets[currentSet].text = encodeSlots(slots) end
        applyLayout()
        hidePicker()
        editor:Hide()
        editPositions(true)
    end
    for i = 1, 12 do
        local index = i
        local item = pickerButton("", 16 + (i - 1) % 3 * 162, -126 - math.floor((i - 1) / 3) * 40, 154, function()
            if InCombatLockdown() then return end
            local slot = 12 * (barPages[currentBar] - 1) + index
            if selectedButton == 8 then
                layout.mainSlot = slot
                commitAction()
                return
            end
            if selectedButton then
                for position, value in ipairs(slots) do
                    if value == slot then
                        if entry then slots[position], slots[entry] = slots[entry], slots[position]
                        else table.remove(slots, position); slots[#slots + 1] = slot end
                        commitAction()
                        return
                    end
                end
                if entry then slots[entry] = slot
                elseif #slots < maxButtons then slots[#slots + 1] = slot
                else note:SetText("O conjunto está cheio. Remova uma ação."); return end
                commitAction()
                return
            end
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
        item.icon = item:CreateTexture(nil, "ARTWORK")
        item.icon:SetSize(26, 26)
        item.icon:SetPoint("LEFT", 5, 0)
        item.name = item:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        item.name:SetPoint("LEFT", 35, 0)
        item.name:SetPoint("RIGHT", -5, 0)
        item.name:SetJustifyH("LEFT")
        item.name:SetWordWrap(false)
        slotControls[i] = item
    end
    local function reorder(step)
        local neighbor = visibleEntries and visibleEntries[visiblePosition + step]
        if InCombatLockdown() or not entry or not neighbor then return end
        slots[entry], slots[neighbor] = slots[neighbor], slots[entry]
        commitAction()
    end
    clear = pickerButton("", 16, -291, 128, function()
        if InCombatLockdown() then return end
        if selectedButton == 8 then
            layout.mainSlot = nil
            commitAction()
        elseif selectedButton then
            if entry then table.remove(slots, entry); commitAction() end
        else
            slots = {}
            displaySlots()
        end
    end)
    earlier = pickerButton("Mover antes", 149, -291, 104, function() reorder(-1) end)
    later = pickerButton("Mover depois", 259, -291, 112, function() reorder(1) end)
    pickerButton("Voltar", 379, -291, 115, function()
        local choosing = selectedButton
        hidePicker()
        if choosing then editor:Hide(); editPositions(true) end
    end)
    confirm = pickerButton("Usar seleção", 259, -291, 112, function()
        lists[currentSet]:SetText(encodeSlots(slots))
        hidePicker()
    end)
    local function openPicker()
        clear:SetText(selectedButton == 8 and "Ataque automático" or selectedButton and "Remover ação" or "Limpar conjunto")
        earlier:SetShown(entry ~= nil and visibleEntries[visiblePosition - 1] ~= nil)
        later:SetShown(entry ~= nil and visibleEntries[visiblePosition + 1] ~= nil)
        confirm:SetShown(not selectedButton)
        displaySlots()
        grip:Hide()
        picker:Show()
    end
    showPicker = function(index)
        currentSet, currentBar, selectedButton, entry = index, 1, nil, nil
        slots = parseSlots(lists[index]:GetText()) or {}
        openPicker()
    end
    showActionPicker = function(index)
        if InCombatLockdown() then return end
        local set, bank = root:GetAttribute("set"), root:GetAttribute("bank")
        currentSet = (set - 1) % 3 + 1
        slots = parseSlots(layout.sets[currentSet].text)
        visiblePosition = math.floor((set - currentSet) / 3) * arcSize + index
        visibleEntries = compiledEntries[bank * 3 + currentSet]
        selectedButton = index
        entry = index <= arcSize and visibleEntries[visiblePosition] or nil
        currentSlot = index == 8 and layout.mainSlot or (entry and slots[entry])
        currentBar = currentSlot and barForPage[math.ceil(currentSlot / 12)] or 1
        openPicker()
    end
    hidePicker = function()
        picker:Hide()
        grip:SetShown(not InCombatLockdown())
    end
    editor:SetScript("OnShow", function()
        stopEditing()
        editor:SetScale(math.min(1, UIParent:GetWidth() / 526, UIParent:GetHeight() / 455))
        grip:ClearAllPoints()
        grip:SetPoint("TOP", editor, "BOTTOM", 0, -4)
        status:SetText(pending and "Alterações na fila até sair de combate." or "")
        load()
    end)
    editor:SetScript("OnHide", function()
        picker:Hide()
        grip:StopMovingOrSizing()
        dragX, dragY = nil, nil
        grip:Hide()
    end)
    events.CloseEditor = function() editor:Hide() end
    events.InvalidateActionPicker = function()
        if selectedButton and picker:IsShown() then editor:Hide() end
    end
    SLASH_SPTOUCHHUD1 = "/sphud"
    SlashCmdList.SPTOUCHHUD = function()
        stopEditing()
        editor:SetShown(not editor:IsShown())
    end
    SLASH_SPTOUCHHUDPAD1 = "/sphudpad"
    SlashCmdList.SPTOUCHHUDPAD = function()
        if not (C_GamePad and C_GamePad.IsEnabled and C_GamePad.GetActiveDeviceID and C_GamePad.GetAllDeviceIDs) then
            print("SPTouchHUD: API de gamepad indisponível.")
            return
        end
        local devices, active = C_GamePad.GetAllDeviceIDs(), C_GamePad.GetActiveDeviceID()
        print("SPTouchHUD: gamepad " .. (C_GamePad.IsEnabled() and "ligado" or "desligado")
            .. " · dispositivos " .. tostring(devices and #devices or 0)
            .. " · ativo " .. tostring(active or "nenhum"))
    end
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
            "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED",
            "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_UPDATE_COOLDOWN", "ACTIONBAR_UPDATE_USABLE",
            "SPELL_UPDATE_USABLE", "SPELL_UPDATE_CHARGES", "PLAYER_TARGET_CHANGED", "UPDATE_SHAPESHIFT_FORM",
            "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR", "UPDATE_STEALTH", "PLAYER_TALENT_UPDATE", "SPELLS_CHANGED",
        }) do events:RegisterEvent(name) end
        applyLayout()
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then
        events.CloseEditor()
        if stopEditing then stopEditing() end
        return
    end
    if event == "PLAYER_ENTERING_WORLD" or event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED"
        or event == "PLAYER_REGEN_ENABLED" then
        if stopEditing then stopEditing() end
        if event ~= "PLAYER_REGEN_ENABLED" then events.CloseEditor() end
        applyLayout()
    elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "ACTIONBAR_PAGE_CHANGED"
        or event == "UPDATE_BONUS_ACTIONBAR" or event == "UPDATE_SHAPESHIFT_FORM" or event == "UPDATE_STEALTH"
        or event == "PLAYER_TALENT_UPDATE" or event == "SPELLS_CHANGED" then
        if InCombatLockdown() then pending = true
        elseif root and not slotsDirty then
            local ticket = {}
            slotsDirty = ticket
            local function recompile()
                if slotsDirty ~= ticket then return end
                slotsDirty = nil
                if InCombatLockdown() then pending = true; return end
                if stopEditing then stopEditing() end
                events.InvalidateActionPicker()
                local largest = compileSlots()
                if layout.classic then placeClassic(largest) end
                for _, button in ipairs(buttons) do
                    if button:IsShown() then refresh(button) end
                end
            end
            if C_Timer and C_Timer.After then C_Timer.After(0, recompile) else recompile() end
        end
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
