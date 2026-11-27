-- Lua 5.1 harness. The secure snippets themselves run with restricted handles and globals.
local unpack = unpack or table.unpack
local combat, secure, page, bonus, target = false, false, 1, nil, false
local frames, nativeWrites, icons, timerCount = {}, 0, {}, 0
local w, h, empty = 844, 390, {}
local cursorX, cursorY
local nativeJoystick = assert(tonumber(arg[2]), "expected UIKit joystick lane fraction")
local nativeJump = assert(tonumber(arg[3]), "expected UIKit Jump lane fraction")
local Frame = {}
Frame.__index = Frame

local function mutation(self)
    if self.native then nativeWrites = nativeWrites + 1 end
    assert(not (self.protected and combat and not secure), "insecure protected mutation in combat")
end

for _, name in ipairs({"SetAlpha", "SetParent", "SetClampedToScreen", "UnregisterAllEvents"}) do
    Frame[name] = mutation
end
for _, name in ipairs({"SetAllPoints", "SetColorTexture", "SetFrameStrata", "SetFrameLevel", "SetVertexColor", "EnableMouse",
                      "SetBackdrop", "SetBackdropColor", "SetAutoFocus", "SetMaxLetters", "ClearFocus",
                      "SetMovable", "RegisterForDrag", "RegisterForClicks", "StopMovingOrSizing",
                      "SetPushedTexture", "SetSwipeTexture", "SetTexCoordRange", "SetTextColor", "SetAtlas"}) do
    Frame[name] = function() end
end

local vehicle
local env = {
    tonumber = tonumber,
    GetActionBarPage = function() return page end,
    HasBonusActionBar = function() return bonus ~= nil end,
    GetBonusBarIndex = function() return bonus end,
    HasVehicleActionBar = function() return vehicle ~= nil end,
    GetVehicleBarIndex = function() return vehicle end,
}
local function run(snippet, self, input)
    local source = "return function(self, message, newstate)\n" .. snippet .. "\nend"
    local chunk
    if setfenv then
        chunk = assert(loadstring(source))
        setfenv(chunk, env)
    else
        chunk = assert(load(source, nil, "t", env))
    end
    local previous = secure
    secure = true
    chunk()(self, input, input)
    secure = previous
end

function Frame:GetParent() return self.parent end
function Frame:GetWidth() return self == UIParent and w or self.width end
function Frame:GetHeight() return self == UIParent and h or self.height end
function Frame:GetScale() return self.scale or 1 end
function Frame:GetEffectiveScale() return self:GetScale() end
function Frame:GetLeft() return self.point[4] end
function Frame:GetBottom() return self.point[5] end
function Frame:GetCenter() return self.point[4], self.point[5] end
function Frame:StartMoving() end
function GetCursorPosition() return cursorX, cursorY end
function Frame:SetScale(value) mutation(self); self.scale = value end
function Frame:SetSize(width, height) mutation(self); self.width, self.height = width, height end
function Frame:SetPoint(...) mutation(self); self.point = {...} end
function Frame:ClearAllPoints() mutation(self); self.point = nil end
function Frame:CreateMaskTexture() return CreateFrame("MaskTexture") end
function Frame:AddMaskTexture(mask)
    self.masks = self.masks or {}
    assert(not self.masks[mask], "duplicate mask")
    self.masks[mask] = true
end
function Frame:RemoveMaskTexture(mask)
    assert(self.masks[mask], "missing mask")
    self.masks[mask] = nil
end
function Frame:GetFrameLevel() return 1 end
function Frame:SetShown(value) if value then self:Show() else self:Hide() end end
function Frame:Show()
    mutation(self)
    if self.shown then return end
    self.shown = true
    if self.scripts.OnShow then self.scripts.OnShow(self) end
end
function Frame:Hide()
    mutation(self)
    if not self.shown then return end
    self.shown = false
    if self.scripts.OnHide then self.scripts.OnHide(self) end
end
function Frame:IsShown() return self.shown end
function Frame:SetScript(script, fn) self.scripts[script] = fn end
function Frame:HookScript(script, fn)
    local old = self.scripts[script]
    self.scripts[script] = function(...)
        if old then old(...) end
        local wasSecure = secure
        secure = false
        fn(...)
        secure = wasSecure
    end
end
function Frame:SetAttribute(name, value)
    mutation(self)
    if self.attrs[name] == value then return end
    self.attrs[name] = value
    if self.scripts.OnAttributeChanged then self.scripts.OnAttributeChanged(self, name, value) end
end
function Frame:GetAttribute(name) return self.attrs[name] end
function Frame:ChildUpdate(kind, value)
    assert(secure)
    for _, child in ipairs(self.children) do
        local snippet = child:GetAttribute("_childupdate-" .. kind)
        if snippet then run(snippet, child, value) end
    end
end
function Frame:Execute(snippet)
    assert(not combat)
    run(snippet, self)
end
function Frame:SetTexture(value) self.texture = value end
function Frame:GetTexture() return self.texture end
function Frame:SetText(value) self.text = value end
function Frame:GetText() return self.text or "" end
function Frame:SetCooldown(start, length, rate) self.timing = {start, length, rate} end
function Frame:Clear() self.timing = nil end
function Frame:CreateTexture() return CreateFrame("Texture") end
function Frame:CreateFontString() return CreateFrame("FontString") end
function Frame:RegisterEvent(name) self.events[name] = true end

function CreateFrame(kind, name, parent, template)
    local frame = setmetatable({kind = kind, parent = parent, template = template, shown = true,
        protected = template and template:match("^Secure"), attrs = {}, scripts = {}, children = {}, events = {}}, Frame)
    if name then _G[name] = frame end
    if parent then table.insert(parent.children, frame) end
    table.insert(frames, frame)
    return frame
end

local function fire(event, arg)
    for _, frame in ipairs(frames) do
        if frame.events[event] then frame.scripts.OnEvent(frame, event, arg) end
    end
end
function RegisterStateDriver(root, name, condition)
    assert(name == "hudpage" and condition:find("[bonusbar:1]", 1, true))
    root.driver = root:GetAttribute("_onstate-" .. name)
end
function InCombatLockdown() return combat end
function UnitExists(unit) return unit == "target" and target end
UIParent = CreateFrame("Frame")
SlashCmdList = {}
for _, bar in ipairs({"MainActionBar", "ActionButton1", "MultiBarBottomLeft", "MultiBarBottomRight",
                      "MultiBarRight", "MultiBarLeft", "MultiBar5", "MultiBar6", "MultiBar7",
                      "MultiBar5Button1", "MultiBarBottomLeftButton1"}) do
    CreateFrame("Frame", bar, UIParent).native = true
end
C_Timer = {NewTicker = function(_, _)
    timerCount = timerCount + 1
    return {Cancel = function() timerCount = timerCount - 1 end}
end}
local secret = {}
function issecretvalue(value) return value == secret end
C_Texture = {GetAtlasInfo = function() return {file = 1} end}
C_ActionBar = {
    HasAction = function(slot) return not empty[slot] end,
    GetActionTexture = function(slot) icons[slot] = (icons[slot] or 0) + 1; return 1000 + slot end,
    GetActionCooldown = function(slot) return {isActive = true, startTime = slot, duration = 12, modRate = 1} end,
    GetActionCharges = function(slot)
        return {isActive = slot == 1, cooldownStartTime = 2, cooldownDuration = 8, chargeModRate = 1}
    end,
    GetActionDisplayCount = function(slot) return slot == 1 and "3" or "" end,
    IsUsableAction = function() return true, false end,
    IsActionInRange = function() return true end,
}

SPTouchHUDCharDB = {scale = "invalid", arcX = 0, sets = {
    [1] = {label = "Principal", color = "abcdef", text = "1,2,3"},
    [3] = {label = "Manual", color = "123456", text = "8:12,7:2,8:1"},
}}
assert(loadfile(assert(arg[1])))("SPTouchHUD")
fire("ADDON_LOADED", "SPTouchHUD")
local hud = assert(SPTouchHUDFrame)
local saved = SPTouchHUDCharDB
assert(saved.version == 4 and saved.arcX == 1 and saved.scale == 1)
assert(saved.sets[1].label == "Principal" and saved.sets[1].color == "abcdef")
assert(saved.sets[3].text == "8:12,7:2,8:1" and saved.sets[2].text == "4,5,6")
print("sptouchhud: v4 migration preserves sparse saved sets and their order")
local first, second = unpack(hud.children)
assert(first:GetAttribute("type") == "action" and first:GetAttribute("action") == 1)
assert(first.icon:GetTexture() == 1001 and first.count.text == "3" and first.cooldown.timing[1] == 1 and first.charge.timing[2] == 8)
print("sptouchhud: slot texture, cooldown, recharge, and count")

icons = {}
fire("ACTIONBAR_SLOT_CHANGED", 2)
assert(icons[2] == 1 and next(icons) == 2 and next(icons, 2) == nil)
assert(second.icon:GetTexture() == 1002)
local getCooldown = C_ActionBar.GetActionCooldown
C_ActionBar.GetActionCooldown = function() return {isActive = secret} end
fire("ACTIONBAR_UPDATE_COOLDOWN")
assert(first.cooldown.timing == nil)
C_ActionBar.GetActionCooldown = getCooldown
print("sptouchhud: single-slot refresh and restricted cooldown values")

combat = true
page = 4
run(hud.driver, hud, 4)
assert(first:GetAttribute("action") == 37)
page, bonus = 1, 9
run(hud.driver, hud, "bonus3")
assert(first:GetAttribute("action") == 97)
for _, child in ipairs(hud.children) do
    if child:GetAttribute("select-set") == 2 then run(child:GetAttribute("_onclick"), child) end
end
assert(first:GetAttribute("action") == 25 and second:GetAttribute("action") == 26)
local pageButton
for _, child in ipairs(hud.children) do
    if child:GetAttribute("_onclick") and not child:GetAttribute("select-set") then pageButton = child end
end
assert(pageButton)
run(pageButton:GetAttribute("_onclick"), pageButton)
assert(first:GetAttribute("action") == 31 and second:GetAttribute("action") == 32)
print("sptouchhud: secure main page, bonus page, and set select during combat")

local function findChild(parent, caption, index)
    local found = 0
    for _, frame in ipairs(parent.children) do
        if frame:GetText() == caption and frame.scripts.OnClick then
            found = found + 1
            if found == (index or 1) then return frame end
        end
    end
    error("missing editor control: " .. caption)
end

local function click(parent, caption, index)
    local frame = findChild(parent, caption, index)
    frame.scripts.OnClick(frame)
end

local editor, picker
for _, frame in ipairs(UIParent.children) do
    if frame.template == "BackdropTemplate" then editor = frame end
end
for _, frame in ipairs(editor.children) do
    if frame.template == "BackdropTemplate" then picker = frame end
end
SlashCmdList.SPTOUCHHUD()
click(editor, "Slots", 2)
click(picker, "Limpar conjunto")
click(picker, "Barra 6")
click(picker, "4")
click(picker, "Barra 8")
click(picker, "11")
click(picker, "Usar seleção")
click(editor, "Aplicar")
assert(SPTouchHUDCharDB.sets[2].text == "6:4,8:11")
assert(first:GetAttribute("action") == 31)
combat = false
fire("PLAYER_REGEN_ENABLED")
assert(first:GetAttribute("action") == 148 and second:GetAttribute("action") == 179 and not hud.children[3]:IsShown())
assert(nativeWrites == 0)
print("sptouchhud: touch slot picker, queued layout, and zero mutations of native action frames")

target = true
fire("PLAYER_TARGET_CHANGED")
fire("PLAYER_TARGET_CHANGED")
assert(timerCount == 1)
target = false
fire("PLAYER_TARGET_CHANGED")
assert(timerCount == 0)
print("sptouchhud: one range ticker while a target exists")

-- Frame coordinates below are in the logical game rect. The left notch has
-- already been cut on this iPhone fixture. UIKit intersects its 23% lanes
-- with the real safe area, including the untouched inset on the other side.
local function rect(left, bottom, width, height)
    return {left, bottom, left + width, bottom + height}
end
local function contains(a, b)
    local epsilon = 0.001
    return b[1] >= a[1] - epsilon and b[2] >= a[2] - epsilon
        and b[3] <= a[3] + epsilon and b[4] <= a[4] + epsilon
end
local function overlaps(a, b)
    local epsilon = 0.001
    return a[1] < b[3] - epsilon and b[1] < a[3] - epsilon
        and a[2] < b[4] - epsilon and b[2] < a[4] - epsilon
end
local function checkPreset(name, leftHanded, width, height, leftInset, rightInset, bottomInset, topInset)
    w, h = width, height
    click(editor, name)
    if leftHanded and name ~= "Canhoto" then click(editor, "Destro") end
    local scale = hud:GetScale()
    local x, y = hud.point[4] * scale, hud.point[5] * scale
    local safe = rect(leftInset, bottomInset, w - leftInset - rightInset, h - bottomInset - topInset)
    local stickWidth = w * nativeJoystick - (leftHanded and rightInset or leftInset)
    local stick = rect(leftHanded and safe[3] - stickWidth or safe[1], safe[2], stickWidth, safe[4] - safe[2])
    local jumpWidth = math.max(w * nativeJump, 64)
    local jumpLeft = leftHanded and safe[1] or safe[3] - jumpWidth
    local jumpArea = rect(jumpLeft, safe[2], jumpWidth, math.min(64, h * 0.21 + 8 - safe[2]))
    local jump = rect(jumpLeft + (leftHanded and jumpWidth - 56 or 8), safe[2] + 8, 48, 48)
    assert(contains(safe, jumpArea) and contains(jumpArea, jump))
    local bounds = rect(x, y, hud:GetWidth() * scale, hud:GetHeight() * scale)
    local launcher
    for _, child in ipairs(UIParent.children) do
        for _, candidate in ipairs(child.children) do
            if candidate.label and candidate.label:GetText() == "···" then launcher = child end
        end
    end
    local menuScale = assert(launcher):GetScale()
    local menuRect = rect((w - 32 * menuScale) / 2, h + launcher.point[5] * menuScale - 32 * menuScale,
                          32 * menuScale, 32 * menuScale)
    assert(contains(safe, menuRect) and not overlaps(menuRect, stick) and not overlaps(menuRect, jump))
    assert(contains(safe, bounds) and not overlaps(bounds, stick))
    local attack
    for _, child in ipairs(hud.children) do
        if child:GetAttribute("macrotext") == "/startattack" then attack = child end
    end
    assert(attack and attack:GetWidth() == 74)
    local attackX = x + attack.point[4] * scale
    local distance = leftHanded and attackX - safe[1] or safe[3] - attackX
    assert(distance <= 140, "attack too far from the skill-side edge")
    local buttons = {}
    for _, button in ipairs(hud.children) do
        if button.template and button:IsShown() then
            assert(button.point[1] == "CENTER" and button.point[2] == hud)
            local bw, bh = button:GetWidth() * scale, button:GetHeight() * scale
            local buttonRect = rect(x + button.point[4] * scale - bw / 2,
                                    y + button.point[5] * scale - bh / 2, bw, bh)
            assert(contains(bounds, buttonRect))
            assert(not overlaps(buttonRect, jumpArea), "Jump lane overlapped a Lua hit target")
            assert(not overlaps(buttonRect, menuRect), "menu overlapped a Lua hit target")
            for _, other in ipairs(buttons) do assert(not overlaps(buttonRect, other)) end
            buttons[#buttons + 1] = buttonRect
        end
    end
    assert(first:GetWidth() == 56 and second:GetWidth() == 56)
    assert(#buttons == 13, "6 skills, 3 sets, next page, Attack, Target, and Interact")
    if leftHanded then assert(attack.point[4] < first.point[4])
    else assert(attack.point[4] > first.point[4]) end
    print(string.format("sptouchhud: %s %dx%d %s, safe disjoint targets, attack %.1f pt from edge",
        name, w, h, leftHanded and "left" or "right", distance))
end

page, bonus = 1, nil
checkPreset("iPhone MMORPG", false, 844, 390, 47, 0, 21, 0)
checkPreset("Canhoto", true, 844, 390, 0, 47, 21, 0)
checkPreset("iPhone MMORPG", false, 797, 390, 0, 47, 21, 0)
checkPreset("Canhoto", true, 797, 390, 47, 0, 21, 0)
checkPreset("iPhone compacto", false, 797, 390, 0, 47, 21, 0)
checkPreset("iPhone compacto", true, 797, 390, 47, 0, 21, 0)
for _, left in ipairs({false, true}) do
    checkPreset("iPad touchscreen", left, 1280, 800, 0, 0, 20, 24)
    checkPreset("iPad touchscreen", left, 1024, 768, 0, 0, 20, 24)
end
w, h = 844, 390
click(editor, "iPhone MMORPG")

local visited = {}
for _, switch in ipairs(hud.children) do
    local group = switch:GetAttribute("select-set")
    if group then
        run(switch:GetAttribute("_onclick"), switch)
        for _ = 1, hud:GetAttribute("pages-1-" .. group) do
            for i = 1, 6 do
                local slot = assert(hud.children[i]:GetAttribute("action"))
                assert(not visited[slot])
                visited[slot] = true
            end
            run(pageButton:GetAttribute("_onclick"), pageButton)
        end
        assert(hud:GetAttribute("set") == group)
    end
end
local positions = 0
for _ in pairs(visited) do positions = positions + 1 end
assert(positions == 96)
click(editor, "iPhone MMORPG")
print("sptouchhud: all 96 slots across the eight bars are reachable")

for i = 1, 180 do empty[i] = true end
empty[3], empty[11], empty[72], empty[57] = nil, nil, nil, nil
for i = 97, 108 do empty[i] = nil end
fire("ACTIONBAR_SLOT_CHANGED", 0)
assert(first:GetAttribute("action") == 3 and second:GetAttribute("action") == 11)
assert(hud.children[3]:GetAttribute("action") == 72 and hud.children[4]:GetAttribute("action") == 57)
assert(not hud.children[5]:IsShown() and hud:GetAttribute("pages-1-1") == 1)
run(pageButton:GetAttribute("_onclick"), pageButton)
assert(hud:GetAttribute("set") == 1 and first:GetAttribute("action") == 3)
print("sptouchhud: occupied main and fixed slots compact in manual order, skipping empty pages")

combat = true
empty[3], empty[11], empty[72], empty[57], empty[1] = true, true, true, true, nil
fire("ACTIONBAR_SLOT_CHANGED", 0)
fire("UI_SCALE_CHANGED")
assert(first:GetAttribute("action") == 3 and second:GetAttribute("action") == 11)
page, bonus = 1, 9
run(hud.driver, hud, "bonus3")
fire("UPDATE_SHAPESHIFT_FORM")
assert(first:GetAttribute("action") == 97 and hud:GetAttribute("pages-9-1") == 3)
run(pageButton:GetAttribute("_onclick"), pageButton)
assert(first:GetAttribute("action") == 103)
bonus = nil
run(hud.driver, hud, "1")
assert(hud:GetAttribute("set") == 1 and first:GetAttribute("action") == 3)
vehicle = 15
run(hud.driver, hud, "vehicle")
assert(first:GetAttribute("action") == 169 and second:GetAttribute("action") == 170)
vehicle = nil
run(hud.driver, hud, "1")
combat = false
fire("PLAYER_REGEN_ENABLED")
assert(first:GetAttribute("action") == 1 and not second:IsShown())
for _, switch in ipairs(hud.children) do
    if switch:GetAttribute("select-set") == 2 then run(switch:GetAttribute("_onclick"), switch) end
end
run(pageButton:GetAttribute("_onclick"), pageButton)
assert(hud:GetAttribute("set") == 2 and not first:IsShown())
for _, switch in ipairs(hud.children) do
    if switch:GetAttribute("select-set") == 1 then run(switch:GetAttribute("_onclick"), switch) end
end
bonus = 9
fire("UPDATE_BONUS_ACTIONBAR")
assert(first:GetAttribute("action") == 97 and hud:GetAttribute("pages-9-1") == 2)
bonus = nil
fire("ACTIONBAR_PAGE_CHANGED")
assert(first:GetAttribute("action") == 1)
print("sptouchhud: lockdown queue, compiled stance paging, empty set, positional vehicle fallback")

empty = {}
click(editor, "iPhone MMORPG")
click(editor, "Mover botões")
local overlay
for _, frame in ipairs(UIParent.children) do
    for _, child in ipairs(frame.children) do
        if child:GetText() == "Interagir" and child.scripts.OnDragStop then overlay = frame end
    end
end
assert(overlay and overlay:IsShown() and not editor:IsShown())
local proxy = findChild(overlay, "1")
local canvas, toolbar = overlay.children[1], overlay.children[2]
click(overlay, "1")
local scale = hud:GetScale()
cursorX, cursorY = (hud:GetLeft() + 151) * scale, (hud:GetBottom() + 38) * scale
canvas.scripts.OnClick()
assert(math.abs(SPTouchHUDCharDB.positions[1][2] - 38) < 0.001)
proxy.scripts.OnDragStart(proxy)
proxy.point[5] = proxy.point[5] + 4 * scale
proxy.scripts.OnDragStop(proxy)
assert(math.abs(SPTouchHUDCharDB.positions[1][2] - 42) < 0.001)
click(toolbar, "Maior")
assert(first:GetWidth() == 60 and SPTouchHUDCharDB.positions[1][3] == 54)
cursorX, cursorY = 0, 0
canvas.scripts.OnClick()
assert(first:GetWidth() == 60 and math.abs(first.point[5] - 42) < 0.001)
cursorX, cursorY = (hud:GetLeft() + 108) * scale, (hud:GetBottom() + 96) * scale
canvas.scripts.OnClick()
assert(math.abs(first.point[5] - 42) < 0.001, "overlapping hitbox should be rejected")
click(overlay, "Atacar")
click(toolbar, "Menor")
assert(SPTouchHUDCharDB.positions[8][3] == 64)
click(toolbar, "Restaurar botões")
assert(first:GetWidth() == 56 and first.point[5] == 35 and next(SPTouchHUDCharDB.positions) == nil)
combat = true
fire("PLAYER_REGEN_DISABLED")
assert(not overlay:IsShown())
combat = false
fire("PLAYER_REGEN_ENABLED")
SlashCmdList.SPTOUCHHUD()
print("sptouchhud: move by drag or tap, resize, reject unsafe geometry, restore, exit on lockdown")

click(editor, "HUD 2.0 clássico")
assert(SPTouchHUDCharDB.classic and not SPTouchHUDCharDB.hideEmpty)
assert(first:GetWidth() == 44 and hud.children[12]:IsShown() and not pageButton:IsShown())
assert(not next(first.icon.masks))
click(editor, "Restaurar padrão")
assert(not SPTouchHUDCharDB.classic and not SPTouchHUDCharDB.left and SPTouchHUDCharDB.hideEmpty)
assert(SPTouchHUDCharDB.sets[2].text == "2" and hud:GetAttribute("set") == 1)
assert(first:GetWidth() == 56 and not hud.children[7]:IsShown() and pageButton:IsShown())
assert(next(first.icon.masks))
assert(nativeWrites == 0)
print("sptouchhud: classic fallback, reset, and zero mutations of native action frames")
