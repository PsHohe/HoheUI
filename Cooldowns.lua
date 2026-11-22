-- Cooldowns: Blizzard's Cooldown Manager, placed on the HUD and drawn in
-- HoheUI's look. Its essential row sits above the player frame, the utility
-- row under it, then tracked buffs. Blizzard still decides which spells show
-- (its Cooldown Settings) and what each icon's sweep means: a cooldown, or
-- in gold your aura or DoT from that spell.
--
-- The rows are Edit Mode systems. One left in its default spot belongs to
-- Blizzard's bottom container, which lays it out with other frames, so it's
-- left alone: move it once in Edit Mode (anywhere) and HoheUI takes it.
-- Moved through the plain SetPoint, not Edit Mode's, so Edit Mode doesn't
-- record a snap to HoheUI's frames.
--
-- Icons are pooled and change spell, so each one is set up once when a row
-- first takes it, and everything HoheUI keeps about it lives in tables here,
-- never as keys on Blizzard's frames. Cooldowns are secret in combat: nothing
-- here reads one, it only reads what the game leaves open (whether a spell
-- is short of power, whether it's cooling down) and hands power to a bar.
--
-- /hoheui cooldowns reports each row, and any action Blizzard blocks
-- because of HoheUI is printed as it happens.
local addonName, ns = ...

local C = ns.COLORS
local IsSecret = ns.IsSecret

local GAP_ABOVE = 8 -- essential row to the player name
local GAP_BELOW = 6 -- utility row to the bottom of the player frame
local GAP_ROWS = 4
local INSET = 2 -- icon art inside the item, so the edge fits in its gaps
local OVERLAY_ATLAS = "UI-HUD-CoolDownManager-IconOverlay"
local FILL_ALPHA = 0.55
local SHORT_TINT = { 0.45, 0.45, 0.5 } -- the icon under a rising fill

local db = ns.AddOptions("cooldowns", {
    { key = "enabled", kind = "toggle", label = "Cooldown rows on the HUD", default = true, reload = true,
      hint = "Places Blizzard's Cooldown Manager around the player frame. Off leaves it to Blizzard and Edit Mode." },
    { key = "skin", kind = "toggle", label = "HoheUI look", default = true, reload = true,
      hint = "Square icons with a black edge and HoheUI's numbers." },
    { key = "fill", kind = "toggle", label = "Power fill", default = true,
      hint = "An icon short of energy, rage or mana fills up toward the spell's cost." },
})

-- Each row and where it goes. `under` is the row it hangs from, if HoheUI
-- placed that one; otherwise it hangs from the player frame.
local ROWS = {
    { name = "EssentialCooldownViewer", point = "BOTTOM", relativePoint = "TOP", y = GAP_ABOVE },
    { name = "UtilityCooldownViewer", point = "TOP", relativePoint = "BOTTOM", y = -GAP_BELOW },
    { name = "BuffIconCooldownViewer", point = "TOP", relativePoint = "BOTTOM", y = -GAP_ROWS,
      under = "UtilityCooldownViewer" },
}

local placed = {} -- viewer -> true while HoheUI holds it
local setUp = setmetatable({}, { __mode = "k" }) -- item -> true once set up
local fills = setmetatable({}, { __mode = "k" }) -- essential and utility item -> its power fill
local filling = setmetatable({}, { __mode = "k" }) -- item -> power type, while its fill shows
local skinning = false -- whether HoheUI draws the icons

-- Placing ------------------------------------------------------------------------

local function Owned(viewer)
    return viewer and viewer.IsInitialized and viewer:IsInitialized() and not viewer:IsInDefaultPosition()
end

local PlaceAll

local function Place(row)
    local viewer = _G[row.name]
    if not viewer then return end
    placed[viewer] = nil
    if not Owned(viewer) then return end
    if InCombatLockdown() and viewer:IsProtected() then
        ns.AfterCombat(PlaceAll)
        return
    end
    local anchor = ns.player
    local under = row.under and _G[row.under]
    if under and placed[under] then anchor = under end
    -- Offsets are in canvas units; the row has its own scale.
    local y = row.y * ns.root:GetEffectiveScale() / viewer:GetEffectiveScale()
    local clear = viewer.ClearAllPointsBase or viewer.ClearAllPoints
    local setPoint = viewer.SetPointBase or viewer.SetPoint
    clear(viewer)
    setPoint(viewer, row.point, anchor, row.relativePoint, 0, y)
    placed[viewer] = true
end

function PlaceAll()
    for _, row in ipairs(ROWS) do Place(row) end
end

-- The look -----------------------------------------------------------------------
-- Blizzard's rounded mask and frame art go; the art is cropped past its own
-- bevel, inset so a black edge fits round it, and the sweep goes flat.
-- Blizzard sets the sweep's colour on every refresh, so its dark cooldown
-- and gold aura colours stay.

local function Skin(item)
    local icon = item.Icon
    for _, region in ipairs({ item:GetRegions() }) do
        local kind = region:GetObjectType()
        if kind == "MaskTexture" then
            icon:RemoveMaskTexture(region)
        elseif kind == "Texture" and region:GetAtlas() == OVERLAY_ATLAS then
            region:SetAlpha(0)
        end
    end
    icon:ClearAllPoints()
    icon:SetPoint("TOPLEFT", item, "TOPLEFT", INSET, -INSET)
    icon:SetPoint("BOTTOMRIGHT", item, "BOTTOMRIGHT", -INSET, INSET)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local edge = item:CreateTexture(nil, "BACKGROUND")
    edge:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(0, 0, 0, 1)
    if item.OutOfRange then item.OutOfRange:SetAllPoints(icon) end

    -- Numbers sized to the icon: 18 on an essential, 11 on a utility one.
    local width = item:GetWidth()
    local cooldown = item.Cooldown
    if cooldown then
        cooldown:ClearAllPoints()
        cooldown:SetAllPoints(icon)
        cooldown:SetSwipeTexture(ns.TEXTURE)
        local countdown = cooldown.GetCountdownFontString and cooldown:GetCountdownFontString()
        if countdown then countdown:SetFont(ns.FONT_NUMBER, math.floor(width * 0.36 + 0.5), "OUTLINE") end
    end
    local count = item.ChargeCount and item.ChargeCount.Current or item.Applications and item.Applications.Applications
    if count then count:SetFont(ns.FONT_NUMBER, math.max(10, math.floor(width * 0.26 + 0.5)), "OUTLINE") end
end

-- The power fill ---------------------------------------------------------------------
-- While a spell is off cooldown but short of power, its icon dims and fills
-- from the bottom in the power's colour: the bar runs from nothing to the
-- spell's cost, and your power, secret or not, goes straight into it.

-- The power type and amount the spell needs, if it's short of it and not
-- cooling down (the global cooldown doesn't count).
local function Shortfall(item)
    local spellID = item:GetSpellID()
    if type(spellID) ~= "number" or IsSecret(spellID) then return end
    local _, short = C_Spell.IsSpellUsable(spellID)
    if IsSecret(short) or not short then return end
    local cooldown = C_Spell.GetSpellCooldown(spellID)
    if cooldown and not IsSecret(cooldown.isActive) and cooldown.isActive
        and not IsSecret(cooldown.isOnGCD) and not cooldown.isOnGCD then
        return
    end
    for _, cost in ipairs(C_Spell.GetSpellPowerCost(spellID) or {}) do
        -- A finisher needs its least cost to cast at all.
        local need = cost.cost
        if not IsSecret(cost.minCost) and type(cost.minCost) == "number" and cost.minCost > 0 then
            need = cost.minCost
        end
        if type(need) == "number" then return cost.type, need end
    end
end

local function UpdateFill(item)
    local fill = fills[item]
    if not fill then return end
    local powerType, need
    if db.fill then powerType, need = Shortfall(item) end
    if not powerType then
        local was = filling[item]
        filling[item] = nil
        fill:Hide()
        -- Blizzard puts its own tint back over the dimmed icon.
        if was then item:RefreshIconColor() end
        return
    end
    local color = ns.POWER_COLORS[powerType] or C.text
    fill:SetStatusBarColor(color[1], color[2], color[3], FILL_ALPHA)
    fill:SetMinMaxValues(0, need)
    fill:SetValue(UnitPower("player", powerType))
    fill:Show()
    filling[item] = powerType
    -- Blizzard tints it blue for "not enough mana", or red out of range,
    -- which wins.
    local outOfRange = item.spellOutOfRange
    if IsSecret(outOfRange) or not outOfRange then
        item.Icon:SetVertexColor(SHORT_TINT[1], SHORT_TINT[2], SHORT_TINT[3])
    end
end

local function CreateFill(item)
    local fill = CreateFrame("StatusBar", nil, item)
    fill:SetAllPoints(item.Icon)
    fill:SetOrientation("VERTICAL")
    fill:SetStatusBarTexture(ns.TEXTURE)
    fill:SetFrameLevel(item:GetFrameLevel())
    fill:Hide()
    fills[item] = fill
    -- Blizzard recolours the icon when usability changes and refreshes
    -- the sweep when the cooldown does; the fill follows both.
    hooksecurefunc(item, "RefreshIconColor", UpdateFill)
    hooksecurefunc(item, "RefreshSpellCooldownInfo", UpdateFill)
end

local function SetUp(item)
    if setUp[item] or not item.Icon then return end
    setUp[item] = true
    if skinning then Skin(item) end
    if item.RefreshIconColor and item.RefreshSpellCooldownInfo then CreateFill(item) end
    UpdateFill(item)
end

local function EachItem(fn)
    for _, row in ipairs(ROWS) do
        local pool = _G[row.name] and _G[row.name].itemFramePool
        if pool then
            for item in pool:EnumerateActive() do fn(item) end
        end
    end
end

-- Hooks ----------------------------------------------------------------------------

local function Hook()
    for _, row in ipairs(ROWS) do
        local viewer = _G[row.name]
        if viewer then
            -- Edit Mode re-anchors a row whenever a layout applies (entering
            -- the world, switching layouts) or the row is dragged.
            if viewer.ApplySystemAnchor then
                hooksecurefunc(viewer, "ApplySystemAnchor", function()
                    Place(row)
                    -- The row under it follows.
                    for _, other in ipairs(ROWS) do
                        if other.under == row.name then Place(other) end
                    end
                end)
            end
            if viewer.OnAcquireItemFrame then
                hooksecurefunc(viewer, "OnAcquireItemFrame", function(_, item) SetUp(item) end)
            end
        end
    end
end

-- /hoheui cooldowns -----------------------------------------------------------------

local function Describe(row)
    local viewer = _G[row.name]
    if not viewer then return row.name .. ": missing" end
    local parts = {}
    local protected = viewer:IsProtected()
    parts[#parts + 1] = protected and "protected" or "not protected"
    if not (viewer.IsInitialized and viewer:IsInitialized()) then
        parts[#parts + 1] = "Edit Mode not applied yet"
    elseif viewer:IsInDefaultPosition() then
        parts[#parts + 1] = "default spot (move it once in Edit Mode)"
    end
    parts[#parts + 1] = placed[viewer] and "placed by HoheUI" or "not placed"
    local _, relativeTo = viewer:GetPoint(1)
    local relativeName = relativeTo and relativeTo.GetName and relativeTo:GetName() or "nothing"
    parts[#parts + 1] = "anchored to " .. tostring(relativeName)
    parts[#parts + 1] = viewer:IsShown() and "shown" or "hidden"
    return row.name .. ": " .. table.concat(parts, ", ")
end

local function Report()
    local enabled = C_CVar and C_CVar.GetCVarBool and C_CVar.GetCVarBool("cooldownViewerEnabled")
    print("HoheUI: cooldown rows (Cooldown Manager " .. (enabled and "on" or "off or unknown") .. ")")
    for _, row in ipairs(ROWS) do print("  " .. Describe(row)) end
    local look = skinning and "HoheUI's"
        or db.skin and "Blizzard's (ForeverEnhancedCooldownManager draws them)"
        or "Blizzard's"
    local shown = 0
    for _ in pairs(filling) do shown = shown + 1 end
    print("  Icons: " .. look .. " look; " .. shown .. " filling toward their cost")
end

ns.AddCommand("cooldowns", "check the cooldown rows", Report)

-- Events -----------------------------------------------------------------------

local events = CreateFrame("Frame")
local handlers = {}

-- Blizzard blocked something and blames HoheUI: say so straight away, so a
-- problem from moving the rows shows up while testing.
local function Blocked(blamed, action)
    if blamed ~= addonName then return end
    print("HoheUI: Blizzard blocked " .. tostring(action) .. (InCombatLockdown() and " (in combat)" or ""))
end
handlers.ADDON_ACTION_BLOCKED = Blocked
handlers.ADDON_ACTION_FORBIDDEN = Blocked

-- Only the fills showing need power; when there's enough, Blizzard's
-- usable update hides them.
function handlers.UNIT_POWER_FREQUENT()
    for item, powerType in pairs(filling) do
        fills[item]:SetValue(UnitPower("player", powerType))
    end
end

events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)

ns.Watch("cooldowns", "enabled", function(on)
    if not on or not _G.EssentialCooldownViewer then return end
    -- Two skins on the same icons would fight; that addon keeps them.
    local other = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("ForeverEnhancedCooldownManager")
    skinning = db.skin and not other
    Hook()
    events:RegisterEvent("ADDON_ACTION_BLOCKED")
    events:RegisterEvent("ADDON_ACTION_FORBIDDEN")
    events:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
    PlaceAll()
    EachItem(SetUp)
end)

ns.Watch("cooldowns", "fill", function() EachItem(UpdateFill) end)
