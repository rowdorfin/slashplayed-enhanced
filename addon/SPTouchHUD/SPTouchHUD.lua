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
local arcWidth, arcHeight = 270, 226
-- Matched against the shim by addon/test/test.sh.
local joystickLane, jumpLane = 0.23, 0.09
local hudWidth = 1 - joystickLane - jumpLane
-- Coordinates include the hit rectangle, which extends three units beyond the face.
local arc = {{233, 87, 68}, {140, 32, 50}, {105, 89, 50},
             {120, 149, 50}, {177, 181, 50}, {236, 155, 50}}
local border = {0.64, 0.77, 0.79}
local dark = {0.06, 0.09, 0.12}
local circleFile = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local maxButtons = 48
local maxSlot = (barPages[#barPages]) * 12
local layoutFields = {
    {"scale", 0.55, 1.8, 1}, {"opacity", 0.2, 1, 0.94}, {"spacing", 0, 24, 5},
    {"columns", 4, 10, 6}, {"count", 1, maxButtons, maxButtons},
}
local colors = {"4bdace", "ffba60", "c9a2ff"}
local root, buttons, switches, utilities, editor, pending, ticker
local account, layout, menu, nextPage, appliedClassic, resetSelection
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
        columns = preset[3], count = maxButtons, left = index == 4, classic = index == 5,
        hideEmpty = index ~= 5, auxiliaries = true, sets = {}}
    for i = 1, 3 do
        layout.sets[i] = {label = "Conjunto " .. i, color = colors[i], text = preset[3 + i]}
    end
    SPTouchHUDCharDB = layout
    resetSelection = true
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
    layout.classic = layout.classic == true
    layout.arcX = bound(layout.arcX, 1, 0, 1)
    layout.arcY = bound(layout.arcY, 0, 0, 1)
    layout.hideEmpty = layout.hideEmpty ~= false
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
        if self:GetParent():GetAttribute("empty-" .. slot) then slot = nil end
    end
    self:SetAttribute("action", slot)
    if slot then self:Show() else self:Hide() end
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
    local next = ((active - group) / 3 + 1) % hud:GetAttribute("pages-" .. group)
    local set = group + next * 3
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
    for i = 1, maxButtons do
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
        buttons[i] = button
    end
    for i = 1, 3 do
        local button = textButton(root, "", nil, "SecureHandlerClickTemplate")
        button:SetAttribute("select-set", i)
        button:SetAttribute("_onclick", selectSet)
        switches[i] = button
    end
    nextPage = textButton(root, "", nil, "SecureHandlerClickTemplate")
    nextPage:SetAttribute("_onclick", cyclePage)
    root:HookScript("OnAttributeChanged", function(_, name, value)
        if name == "set" then
            local group = (value - 1) % 3 + 1
            for i, button in ipairs(switches) do
                if i == group then button.bg:SetColorTexture(0.22, 0.33, 0.36, 1)
                else button.bg:SetColorTexture(dark[1], dark[2], dark[3], 0.82) end
            end
            nextPage.label:SetText(math.floor((value - 1) / 3) + 1 .. " ›")
            nextPage.bg:SetColorTexture(dark[1], dark[2], dark[3],
                root:GetAttribute("pages-" .. group) > 1 and 0.82 or 0.50)
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
    local utilityParent = CreateFrame("Frame", nil, UIParent)
    utilityParent:SetFrameStrata("HIGH")
    utilityParent:SetSize(182, 44)
    menu = textButton(utilityParent, "···", nil, "BackdropTemplate")
    menu:SetSize(44, 44)
    menu:SetPoint("TOP", utilityParent, "TOP")
    local panel = CreateFrame("Frame", nil, utilityParent)
    panel:SetSize(176, 162)
    panel:SetPoint("TOP", menu, "BOTTOM", 0, -2)
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
    utility("Bolsas", command("ToggleAllBags"))
    utility("Mapa", command("ToggleWorldMap"))
    utility("Personagem", function() if ToggleCharacter then ToggleCharacter("PaperDollFrame") end end)
    utility("Missões", command("ToggleQuestLog"))
    utility("Grimório", function()
        if PlayerSpellsUtil and PlayerSpellsUtil.ToggleSpellBookFrame then PlayerSpellsUtil.ToggleSpellBookFrame() end
    end)
    utility("Chat", function() if ChatFrameUtil and ChatFrameUtil.OpenChat then ChatFrameUtil.OpenChat(nil) end end)
    utility("Opções", command("ToggleGameMenu"))
    utility("Editar HUD", function() editor:SetShown(not editor:IsShown()) end)
    menu.panel = panel
    root.UpdateInteract = function()
        local available = _G[interactName] ~= nil
        interact:SetAttribute("type", available and "macro" or nil)
        interact.label:SetText(available and "Interagir" or "|cff879496Interagir|r")
    end
    RegisterStateDriver(root, "hudpage", "[vehicleui]vehicle; [overridebar]override; [shapeshift]temp; [bar:2]2; [bar:3]3; [bar:4]4; [bar:5]5; [bar:6]6; [bonusbar:1]bonus1; [bonusbar:2]bonus2; [bonusbar:3]bonus3; [bonusbar:4]bonus4; [bonusbar:5]bonus5; 1")
end

local function placeArcMenu(scale)
    local host, panel = menu:GetParent(), menu.panel
    host:ClearAllPoints()
    host:SetScale(scale)
    host:SetAlpha(layout.opacity)
    host:SetPoint("TOP", UIParent, "TOP", 0, -UIParent:GetHeight() * 0.08 / scale)
    host:SetSize(182, 44)
    panel:SetSize(176, 162)
    panel:ClearAllPoints()
    panel:SetPoint("TOP", menu, "BOTTOM", 0, -2)
    for i = 4, #utilities do
        local button, index = utilities[i], i - 4
        button:ClearAllPoints()
        button:SetSize(82, 36)
        button:SetPoint("TOPLEFT", panel, "TOPLEFT", index % 2 * 90, -math.floor(index / 2) * 39)
        setCircular(button, true)
    end
    menu:Show()
    panel:Hide()
    host:SetShown(account.enabled and layout.auxiliaries)
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
        place(button, i, 0)
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
        setCircular(button, false)
    end
    menu:Hide()
    host:SetShown(account.enabled and layout.auxiliaries)
    panel:SetShown(host:IsShown())
end

local function pointScale(width, height)
    return height / (width / height < 1.65 and 768 or 390)
end

local function arcBottom(width, height, scale)
    local point = pointScale(width, height)
    local attack = arc[1]
    local clearance = math.min(height * 0.21, 82 * point)
    return math.max(math.min(height * 0.08, 32 * point), clearance - (attack[2] - (attack[3] + 6) / 2) * scale)
end

local function placeArc()
    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    -- Fit between the asymmetric lanes in game coordinates. The attack starts
    -- above the bottom clearance for Jump when its native safe area has an inset.
    local point = pointScale(w, h)
    local scale = math.min(layout.scale * point, w * hudWidth / arcWidth, h * 0.72 / arcHeight)
    root:SetScale(scale)
    root:SetSize(arcWidth, arcHeight)
    root:ClearAllPoints()
    local x = w * joystickLane + (w * hudWidth - arcWidth * scale) * (layout.arcX or 1)
    if layout.left then x = w - x - arcWidth * scale end
    local bottom = arcBottom(w, h, scale)
    local y = bottom + math.max(0, h * 0.80 - bottom - arcHeight * scale) * (layout.arcY or 0)
    root:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    local function place(button, x, y, size, height)
        button:ClearAllPoints()
        button:SetSize(size + 6, (height or size) + 6)
        button:SetPoint("CENTER", root, "BOTTOMLEFT", layout.left and arcWidth - x or x, y)
    end
    for i, cell in ipairs(arc) do
        local button = buttons[i]
        place(button, unpack(cell))
        styleAction(button, true)
    end
    for i, button in ipairs(switches) do
        place(button, 19 + (i - 1) * 34, 205, 26)
        setCircular(button, true)
    end
    place(nextPage, 121, 205, 26)
    place(utilities[3], 64, 24, 68, 36)
    setCircular(utilities[3], true)
    placeArcMenu(math.min(point, w / 320, h / 400))
end

local function snapshotSlot(slot)
    local hasAction = api.HasAction or HasAction
    local occupied = hasAction and hasAction(slot)
    root:SetAttribute("empty-" .. slot, layout.hideEmpty and readable(occupied) and occupied == false or nil)
end

local function applyLayout()
    if InCombatLockdown() then pending = true; return end
    pending = false
    if not root then createHUD() end
    local compiled, largest = {}, 0
    for i, set in ipairs(layout.sets) do
        local slots = parseSlots(set.text) or {}
        compiled[i] = slots
        local count = math.min(layout.count, #slots)
        largest = math.max(largest, count)
        root:SetAttribute("pages-" .. i, layout.classic and 1 or math.max(1, math.ceil(count / arcSize)))
        local label = layout.classic and set.label or tostring(i)
        switches[i].label:SetText("|cff" .. set.color .. label .. "|r")
    end
    if resetSelection then
        resetSelection = nil
        root:SetAttribute("set", 1)
    end
    local active = root:GetAttribute("set")
    local group = (active - 1) % 3 + 1
    if math.floor((active - 1) / 3) >= root:GetAttribute("pages-" .. group) then
        root:SetAttribute("set", group)
    end
    for i, button in ipairs(buttons) do
        for set = 1, 3 do
            local slot = (layout.classic or i <= arcSize) and i <= layout.count and compiled[set][i]
            button:SetAttribute("slot-" .. set, slot or nil)
            if i <= arcSize then
                for page = 1, maxButtons / arcSize - 1 do
                    local index = i + arcSize * page
                    slot = not layout.classic and index <= layout.count and compiled[set][index]
                    button:SetAttribute("slot-" .. (set + page * 3), slot or nil)
                end
            end
        end
    end
    for slot = 1, maxSlot do snapshotSlot(slot) end
    root:SetAlpha(layout.opacity)
    if layout.classic then placeClassic(largest) else placeArc() end
    appliedClassic = layout.classic
    switches[group].bg:SetColorTexture(0.22, 0.33, 0.36, 1)
    local pages = root:GetAttribute("pages-" .. group)
    nextPage.label:SetText(math.floor((root:GetAttribute("set") - 1) / 3) + 1 .. " ›")
    nextPage:SetShown(not layout.classic)
    nextPage.bg:SetColorTexture(dark[1], dark[2], dark[3], pages > 1 and 0.82 or 0.50)
    for i = 1, 3 do utilities[i]:SetShown(layout.auxiliaries and (layout.classic or i == 3)) end
    root:UpdateInteract()
    root:Execute(updatePage)
    root:SetShown(account.enabled)
    syncTicker()
end

local function createEditor()
    editor = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    editor:SetSize(510, 360)
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
        if index == 3 or index == 4 then
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
        aux:SetText(layout.auxiliaries and "Auxiliares ✓" or "Auxiliares")
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
        button(preset[1], 16 + (i - 1) % 3 * 162, -264 - math.floor((i - 1) / 3) * 30, 156,
            function() usePreset(index); applyLayout(); load() end)
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
            local width, height = arcWidth * root:GetScale(), arcHeight * root:GetScale()
            layout.arcX = bound((x - width / 2 - w * joystickLane) / math.max(1, w * hudWidth - width), 1, 0, 1)
            local bottom = arcBottom(w, h, root:GetScale())
            layout.arcY = bound((y - height / 2 - bottom) / math.max(1, h * 0.80 - bottom - height), 0, 0, 1)
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
        editor:SetScale(math.min(1, UIParent:GetWidth() / 526, UIParent:GetHeight() / 408))
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
            "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED",
            "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_UPDATE_COOLDOWN", "ACTIONBAR_UPDATE_USABLE",
            "SPELL_UPDATE_USABLE", "SPELL_UPDATE_CHARGES", "PLAYER_TARGET_CHANGED", "UPDATE_SHAPESHIFT_FORM",
        }) do events:RegisterEvent(name) end
        applyLayout()
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then events.CloseEditor(); return end
    if event == "PLAYER_ENTERING_WORLD" or event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED"
        or (event == "PLAYER_REGEN_ENABLED" and pending) then
        applyLayout()
    end
    if not root or not root:IsShown() then return end
    if event == "ACTIONBAR_SLOT_CHANGED" and (layout.hideEmpty or pending) then
        if InCombatLockdown() then
            pending = true
        elseif not arg or arg == 0 then
            for slot = 1, maxSlot do snapshotSlot(slot) end
            root:Execute(updatePage)
        elseif arg >= 1 and arg <= maxSlot then
            local before = root:GetAttribute("empty-" .. arg)
            snapshotSlot(arg)
            if before ~= root:GetAttribute("empty-" .. arg) then
                root:Execute(updatePage)
                return -- Attribute hooks refreshed the affected visible buttons.
            end
        end
    end
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
