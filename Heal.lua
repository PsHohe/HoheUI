-- Heal pick: Controller Forever's Healer D-pad (/cr healer on) picks the
-- party member your helpful spells go to, without touching your target, and
-- casts them there from every controller button. HoheUI shows that pick on
-- its party tiles and lets a click on a tile pick too.
--
-- Controller Forever keeps the pick on its secure header,
-- ControllerForeverHealHeader: "mode" ("dpad", "five" or "off") and "unit"
-- (who the heals go to now). A tile click writes the same attributes its
-- D-pad does, from secure code, so it works in combat. That leans on
-- Controller Forever's internals; recheck it when Controller Forever updates.
--
-- Without Controller Forever, or with its healer off, a tile click targets.
local addonName, ns = ...

local header
local tiles = {}

-- The unit the heals go to, or nil when there's no healer pick.
function ns.GetHealPick()
    if not header then return nil end
    local mode = header:GetAttribute("mode")
    if mode ~= "dpad" and mode ~= "five" then return nil end
    return header:GetAttribute("unit")
end

-- Secure code that picks `unit` on Controller Forever's header `h` the way
-- its D-pad does. Pasted into snippets that have both as locals.
ns.HEAL_PICK = [[
    for i = 1, (h:GetAttribute("count") or 0) do
        if h:GetAttribute("unit-" .. i) == unit then
            h:SetAttribute("index", i)
            break
        end
    end
    h:SetAttribute("picked", unit)
    h:SetAttribute("override", 1)
    control:RunFor(h, h:GetAttribute("cr-apply"))
]]

-- A plain left-click on a tile: pick its member, or target it when the
-- healer is off.
local PICK_BODY = [[
    if button ~= "LeftButton" or IsShiftKeyDown() then return end
    local h = self:GetFrameRef("cf-heal")
    local mode = h and h:GetAttribute("mode")
    if mode ~= "dpad" and mode ~= "five" then
        self:SetAttribute("type1", "target")
        return
    end
    self:SetAttribute("type1", nil)
    local unit = self:GetAttribute("unit")
]] .. ns.HEAL_PICK

-- Tiles are SecureHandlerBaseTemplate buttons; they're wired up once the
-- header exists.
function ns.AddHealTile(tile)
    tiles[#tiles + 1] = tile
end

-- Other secure frames that pick (the arch, Arch.lua) only need the header,
-- as the frame ref "cf-heal".
local refs = {}
function ns.AddHealRef(frame)
    refs[#refs + 1] = frame
end

local function Bridge()
    if header or InCombatLockdown() then return end
    header = _G.ControllerForeverHealHeader
    if not header then return end
    header:HookScript("OnAttributeChanged", function(_, name)
        if name == "unit" or name == "mode" then ns.OnHealSelectionChanged() end
    end)
    for _, tile in ipairs(tiles) do
        SecureHandlerSetFrameRef(tile, "cf-heal", header)
        SecureHandlerWrapScript(tile, "OnClick", tile, PICK_BODY)
    end
    for _, frame in ipairs(refs) do SecureHandlerSetFrameRef(frame, "cf-heal", header) end
    ns.OnHealSelectionChanged()
end

-- Controller Forever builds its header a few seconds after login, in
-- refreshAll; connect then.
local heal = ControllerForever and ControllerForever.HealFocus
if heal and heal.refreshAll then hooksecurefunc(heal, "refreshAll", Bridge) end

local handlers = {}

handlers.PLAYER_ENTERING_WORLD = Bridge
handlers.PLAYER_REGEN_ENABLED = Bridge

local events = CreateFrame("Frame")
for event in pairs(handlers) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)
