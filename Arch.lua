-- Gyro picking: hold the pick button (the controller's screenshot button,
-- set to Gyro to Mouse in Steam Input) and tilt the controller up or down to
-- step the pick through the party column, then let go to pick that member,
-- the way a tile click does: with Controller Forever's healer on they become
-- the heal pick (your target stays), otherwise your target. It starts from
-- the current heal pick (or the last member picked this way, or you) and
-- every step of cursor travel is one tile; where the cursor is doesn't matter.
-- Let go without moving and nothing changes. The tile it's on grows and gets
-- the white border while the button is held.
--
-- The pick on release is made by secure code, which reads the cursor against
-- a full-screen secure frame, so it works in combat. The highlight while held
-- is the same sum done by plain code each frame (the cursor has no event).
--
-- The button is set on the Keybinds page (see Binds.lua); the tilt per tile
-- on the Party page. (File name kept from the arch layout this started as.)
local addonName, ns = ...

local party = ns.AddOptions("party", {
    { kind = "header", label = "Gyro pick" },
    { key = "gyroStep", kind = "range", label = "Tilt per tile", default = 40, min = 20, max = 100, step = 5,
      hint = "Cursor travel that steps the pick one tile, in 1080ths of the screen." },
})
-- Which pad key the screenshot button arrives as is a guess: /hoheui pick says.
local binds = ns.AddOptions("binds", {
    { key = "pick", kind = "bind", label = "Gyro pick (hold)", default = "PADSOCIAL", click = "HoheUIPickHold",
      anyModifier = true, needs = "party", hint = "Hold and tilt the controller to step through the party." },
})

-- Cursor travel per tile, as a share of the screen's height.
local function Step()
    return party.gyroStep / 1080
end

-- How far past a tile's edge, in tiles, the cursor must go before the pick
-- leaves it, so the jolt of letting go doesn't step to the next member.
local SLACK = 0.35

local tiles = ns.partyTiles

-- The screen, for measuring the cursor from secure code.
local area = CreateFrame("Frame", "HoheUIPickArea", UIParent, "SecureHandlerBaseTemplate")
area:SetAllPoints(UIParent)

-- "aiming" is 1 while the button is held; "y0" is where the cursor was then,
-- "held" the steps the pick sits at and "last" the tile last picked this way.
local hold = CreateFrame("Button", "HoheUIPickHold", UIParent, "SecureActionButtonTemplate,SecureHandlerBaseTemplate")
hold:SetSize(1, 1)
hold:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -20, 20)
hold:RegisterForClicks("AnyDown", "AnyUp")
hold:SetAttribute("pressAndHoldAction", true)
hold:SetAttribute("aiming", 0)
hold:SetAttribute("count", #tiles)
hold:SetAttribute("step", Step())
hold:SetAttribute("slack", SLACK)
hold:SetFrameRef("area", area)
for i, tile in ipairs(tiles) do hold:SetFrameRef("tile" .. i, tile) end

-- An invisible strip across the screen over the band of cursor heights that
-- keep the pick where it is (its tile plus the slack either side). Secure
-- code has no per-frame hook, so the strip is how it follows the cursor while
-- held: leaving it moves the pick to the tile under the cursor and the strip
-- with it. Motion only, so clicks go through.
local band = CreateFrame("Frame", "HoheUIPickBand", area, "SecureHandlerEnterLeaveTemplate")
band:SetFrameStrata("TOOLTIP")
band:SetMouseMotionEnabled(true)
band:SetMouseClickEnabled(false)
band:Hide()
band:SetFrameRef("hold", hold)
hold:SetFrameRef("band", band)

-- Run as hold. "place" puts the strip around the held tile. "follow" moves
-- the held tile to the one under the cursor once it's past the slack (the
-- strip can also be left for a frame drawn over it, which changes nothing).
hold:SetAttribute("place", [[
    local band, area = self:GetFrameRef("band"), self:GetFrameRef("area")
    local step, H = self:GetAttribute("step"), area:GetHeight()
    local mid = (self:GetAttribute("y0") - self:GetAttribute("held") * step) * H
    band:ClearAllPoints()
    band:SetPoint("LEFT", area, "BOTTOMLEFT", 0, mid)
    band:SetPoint("RIGHT", area, "BOTTOMRIGHT", 0, mid)
    band:SetHeight((1 + 2 * self:GetAttribute("slack")) * step * H)
]])
hold:SetAttribute("follow", [[
    local _, y = self:GetFrameRef("area"):GetMousePosition()
    local y0 = self:GetAttribute("y0")
    if not (y and y0) then return end
    local raw = (y0 - y) / self:GetAttribute("step")
    local off, reach = raw - self:GetAttribute("held"), 0.5 + self:GetAttribute("slack")
    if off > reach or off < -reach then
        self:SetAttribute("held", floor(raw + 0.5))
        self:RunAttribute("place")
    end
]])

band:SetAttribute("_onleave", [[
    local hold = self:GetFrameRef("hold")
    if hold:GetAttribute("aiming") == 1 then hold:RunAttribute("follow") end
]])

-- Down: note the cursor and put the strip there. Up: step from the start by
-- the held tile, followed once more in case the strip missed the last move.
-- A target is taken by the button's own action on release ("typerelease", or
-- "type" when actions go off on key up).
SecureHandlerWrapScript(hold, "OnClick", hold, [[
    self:SetAttribute("type", nil)
    self:SetAttribute("typerelease", nil)
    local _, y = self:GetFrameRef("area"):GetMousePosition()
    if down then
        self:SetAttribute("y0", y)
        self:SetAttribute("held", 0)
        self:SetAttribute("aiming", 1)
        if y then
            self:RunAttribute("place")
            self:GetFrameRef("band"):Show()
        end
        return false
    end
    self:SetAttribute("aiming", 0)
    self:GetFrameRef("band"):Hide()
    if not (y and self:GetAttribute("y0")) then return false end
    self:RunAttribute("follow")
    local steps = self:GetAttribute("held")
    if steps == 0 then return false end

    local h = self:GetFrameRef("cf-heal")
    local mode = h and h:GetAttribute("mode")
    local healing = mode == "dpad" or mode == "five"
    local current = healing and h:GetAttribute("unit") or nil
    local last = self:GetAttribute("last")
    local shown, start, fallback = newtable(), nil, nil
    for i = 1, self:GetAttribute("count") do
        local tile = self:GetFrameRef("tile" .. i)
        if tile:IsVisible() then
            shown[#shown + 1] = i
            if not start and current and tile:GetAttribute("unit") == current then start = #shown end
            if i == last then fallback = #shown end
        end
    end
    if #shown == 0 then return false end
    start = start or fallback or 1
    local pos = start + steps
    if pos < 1 then pos = 1 elseif pos > #shown then pos = #shown end
    if pos == start then return false end
    local index = shown[pos]
    self:SetAttribute("last", index)
    local unit = self:GetFrameRef("tile" .. index):GetAttribute("unit")
    if not healing then
        self:SetAttribute("unit", unit)
        self:SetAttribute("type", "target")
        self:SetAttribute("typerelease", "target")
        return
    end
]] .. ns.HEAL_PICK .. [[
    return false
]])

ns.AddHealRef(hold)

-- The highlight while held --------------------------------------------------

-- The cursor's height as a share of the screen's, like GetMousePosition.
local function CursorY()
    local _, y = GetCursorPosition()
    local bottom, height = area:GetBottom(), area:GetHeight()
    if not (bottom and height and height > 0) then return nil end
    return (y / area:GetEffectiveScale() - bottom) / height
end

-- The tile the release would pick, by the same rules as the snippet above,
-- or nil before the cursor has gone a step.
local function Aim()
    local y0, y = hold:GetAttribute("y0"), CursorY()
    if not (y0 and y) then return nil end
    local raw, steps = (y0 - y) / Step(), hold:GetAttribute("held") or 0
    if math.abs(raw - steps) > 0.5 + SLACK then steps = math.floor(raw + 0.5) end
    if steps == 0 then return nil end
    local current, last = ns.GetHealPick(), hold:GetAttribute("last")
    local shown, start, fallback = {}, nil, nil
    for i, tile in ipairs(tiles) do
        if tile:IsVisible() then
            shown[#shown + 1] = i
            if not start and current and tile:GetAttribute("unit") == current then start = #shown end
            if i == last then fallback = #shown end
        end
    end
    if #shown == 0 then return nil end
    start = start or fallback or 1
    local pos = math.max(1, math.min(#shown, start + steps))
    if pos == start then return nil end
    return shown[pos]
end

local aim
local watcher = CreateFrame("Frame")

local function Follow()
    local now = Aim()
    if now ~= aim then
        aim = now
        ns.OnHealSelectionChanged()
    end
end

hold:HookScript("OnAttributeChanged", function(_, name, value)
    if name ~= "aiming" then return end
    if value == 1 then
        watcher:SetScript("OnUpdate", Follow)
        Follow()
    else
        watcher:SetScript("OnUpdate", nil)
        aim = nil
        ns.OnHealSelectionChanged()
    end
end)

-- The tile index the pick is on while the button is held, or nil.
function ns.GetArchAim()
    return aim
end

-- /hoheui pick ---------------------------------------------------------------
-- Who has the pick key, whether presses and cursor travel arrive, and the
-- name of the next pad button pressed (to find the screenshot button's).

local presses = 0
hold:HookScript("OnAttributeChanged", function(_, name, value)
    if name == "aiming" and value == 1 then presses = presses + 1 end
end)

local listener = CreateFrame("Frame")
listener:Hide()
listener:SetScript("OnGamePadButtonDown", function(self, button)
    print("HoheUI: that button is " .. button .. (button == binds.pick and " (the pick key)" or ""))
    self:Hide()
end)

function ns.ProbePick()
    local key = binds.pick
    print("HoheUI: pick check (key " .. tostring(key or "not bound") .. ")")
    if key then
        print("  " .. key .. " runs: " .. tostring(GetBindingAction(key, true)))
        local cf = ControllerForever and ControllerForever.Binds
        if cf and cf.resolved then
            local action, claim = cf:resolved(key)
            print("  Controller Forever gives it to: " .. tostring(claim) .. " (" .. tostring(action) .. ")")
        end
    end
    local y0, y = hold:GetAttribute("y0"), CursorY()
    local travel = (y0 and y) and string.format("%.0f units", (y - y0) * 1080) or "unknown"
    print("  presses seen: " .. presses .. "; cursor moved since the last press: " .. travel)
    if InCombatLockdown() or not listener.EnableGamePadButton then return end
    listener:EnableGamePadButton(true)
    listener:Show()
    print("  press the screenshot button within 5 seconds to see its name")
    C_Timer.After(5, function()
        if listener:IsShown() then print("HoheUI: no pad button seen") end
        listener:Hide()
    end)
end

ns.AddCommand("pick", "check the gyro pick button", ns.ProbePick)

local function ApplyStep()
    hold:SetAttribute("step", Step())
end
ns.Watch("party", "gyroStep", function() ns.AfterCombat(ApplyStep) end)
