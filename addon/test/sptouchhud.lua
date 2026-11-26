-- Lua 5.1 harness. The secure snippets themselves run with restricted handles and globals.
local combat, secure, page, bonus, target = false, false, 1, nil, false
local frames, nativeWrites, icons, timerCount = {}, 0, {}, 0
local Frame = {}
Frame.__index = Frame

local function mutation(self)
    if self.native then nativeWrites = nativeWrites + 1 end
    assert(not (self.protected and combat and not secure), "insecure protected mutation in combat")
end

for _, name in ipairs({"SetPoint", "ClearAllPoints", "SetSize", "SetScale", "SetAlpha", "SetParent",
                      "SetClampedToScreen", "UnregisterAllEvents"}) do
    Frame[name] = mutation
end
for _, name in ipairs({"SetAllPoints", "SetColorTexture", "SetFrameStrata", "SetFrameLevel", "SetVertexColor", "EnableMouse",
                      "SetBackdrop", "SetBackdropColor", "SetAutoFocus", "SetMaxLetters", "ClearFocus",
                      "SetMovable", "RegisterForDrag", "RegisterForClicks", "StopMovingOrSizing"}) do
    Frame[name] = function() end
end

local env = {
    tonumber = tonumber,
    GetActionBarPage = function() return page end,
    HasBonusActionBar = function() return bonus ~= nil end,
    GetBonusBarIndex = function() return bonus end,
}
local function run(snippet, self, input)
    local chunk = assert(loadstring("return function(self, message, newstate)\n" .. snippet .. "\nend"))
    setfenv(chunk, env)
    local previous = secure
    secure = true
    chunk()(self, input, input)
    secure = previous
end

function Frame:GetParent() return self.parent end
function Frame:GetWidth() return 1100 end
function Frame:GetHeight() return 650 end
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
C_ActionBar = {
    GetActionTexture = function(slot) icons[slot] = (icons[slot] or 0) + 1; return 1000 + slot end,
    GetActionCooldown = function(slot) return {isActive = true, startTime = slot, duration = 12, modRate = 1} end,
    GetActionCharges = function(slot)
        return {isActive = slot == 1, cooldownStartTime = 2, cooldownDuration = 8, chargeModRate = 1}
    end,
    GetActionDisplayCount = function(slot) return slot == 1 and "3" or "" end,
    IsUsableAction = function() return true, false end,
    IsActionInRange = function() return true end,
}

assert(loadfile(assert(arg[1])))("SPTouchHUD")
fire("ADDON_LOADED", "SPTouchHUD")
local hud = assert(SPTouchHUDFrame)
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
assert(first:GetAttribute("action") == 61 and second:GetAttribute("action") == 62)
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
assert(first:GetAttribute("action") == 61)
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
