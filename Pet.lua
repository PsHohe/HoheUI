-- Pet frame: your pet, centred under the player frame. A health bar with the
-- percent inside it and a thin power bar beneath; the name above, with a
-- happiness tag for hunter pets. Click to target the pet, right-click for its
-- menu. It fades along with the player frame, which stays lit while the pet
-- is hurt.
local _, ns = ...

local C = ns.COLORS
local IsSecret = ns.IsSecret

local WIDTH = 200

-- Happiness levels from C_PetInfo.GetPetHappiness.
local HAPPINESS = {
    [1] = { label = "UNHAPPY", color = C.hostile },
    [2] = { label = "CONTENT", color = C.neutral },
    [3] = { label = "HAPPY", color = C.friendly },
}

local db = ns.AddOptions("pet", {
    { key = "enabled", kind = "toggle", label = "Pet frame", default = true, reload = true },
    { key = "scale", kind = "range", label = "Size", default = 1, min = 0.5, max = 2, step = 0.05, percent = true },
})
local player = ns.Settings("player")

-- Protected, so it hangs off the canvas rather than the player frame.
local f = CreateFrame("Button", "HoheUIPet", ns.root, "SecureUnitButtonTemplate")
f:SetSize(WIDTH, 44)

-- Its top sits under the player frame's swing timer (the player frame is 72
-- tall, at its own size) and the cooldown rows below it. Only out of combat.
local function Place()
    local scale = db.scale
    f:SetScale(scale)
    f:ClearAllPoints()
    f:SetPoint("TOP", ns.root, "CENTER", 0, (ns.PLAYER_TOP - 86 * player.scale - ns.UNDER_PLAYER) / scale)
end
Place()
f:SetAttribute("unit", "pet")
f:SetAttribute("*type1", "target")
f:SetAttribute("*type2", "togglemenu")
f:RegisterForClicks("AnyUp")

f.name = ns.CreateText(f, 13, ns.FONT_TEXT, C.muted)
f.name:SetPoint("TOP", f, "TOP", 0, 0)

f.happiness = ns.CreateText(f, 11, ns.FONT_NUMBER, C.muted)
f.happiness:SetPoint("LEFT", f.name, "RIGHT", 6, 0)

f.healthBar = ns.CreateHealthBar(f, 16)
f.healthBar:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -18)
f.healthBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -18)
f.healPrediction = ns.CreateHealPrediction(f.healthBar)

f.powerBar = ns.CreateBar(f, 6, C.focus)
f.powerBar:SetPoint("TOPLEFT", f.healthBar, "BOTTOMLEFT", 0, -4)
f.powerBar:SetPoint("TOPRIGHT", f.healthBar, "BOTTOMRIGHT", 0, -4)

f.health = ns.CreateBarText(f.healthBar, 13, C.text)
f.health:SetPoint("CENTER", f.healthBar, "CENTER", 0, 0)

-- Values -----------------------------------------------------------------------

local function UpdateName()
    f.name:SetText(UnitName("pet"))
end

local function UpdateHappiness()
    local _, isHunterPet = HasPetUI()
    local happiness = isHunterPet and C_PetInfo and C_PetInfo.GetPetHappiness and C_PetInfo.GetPetHappiness()
    local level = not IsSecret(happiness) and HAPPINESS[happiness]
    if not level then
        f.happiness:SetText("")
        return
    end
    f.happiness:SetText(level.label)
    f.happiness:SetTextColor(level.color[1], level.color[2], level.color[3])
end

local function UpdateHealth()
    local cur, max = UnitHealth("pet"), UnitHealthMax("pet")
    f.healthBar:SetMinMaxValues(0, max)
    f.healthBar:SetValue(cur)
    ns.UpdateHealPrediction(f.healPrediction, "pet")
    local dead = UnitIsDead("pet")
    if not IsSecret(dead) and dead then
        f.health:SetText("Dead")
    else
        ns.SetHealthPercent(f.health, "pet")
    end
    ns.UpdatePlayerAlpha()
end

local function UpdatePowerType()
    local kind = UnitPowerType("pet")
    local color = not IsSecret(kind) and ns.POWER_COLORS[kind] or C.focus
    f.powerBar:SetStatusBarColor(color[1], color[2], color[3])
end

local function UpdatePower()
    f.powerBar:SetMinMaxValues(0, UnitPowerMax("pet"))
    f.powerBar:SetValue(UnitPower("pet"))
end

-- Unknown (secret) counts as there.
local function PetExists()
    local exists = UnitExists("pet")
    return IsSecret(exists) or exists
end

local function UpdateAll()
    if not PetExists() then return end
    UpdateName()
    UpdateHappiness()
    UpdateHealth()
    UpdatePowerType()
    UpdatePower()
end

-- Shown while the pet exists; the game handles it, so it works in combat.
RegisterUnitWatch(f)
f:HookScript("OnShow", UpdateAll)
f:HookScript("OnHide", ns.UpdatePlayerAlpha)

-- Follow the player frame's fade.
f:SetAlpha(ns.player:GetAlpha())
hooksecurefunc(ns.player, "SetAlpha", function(_, alpha) f:SetAlpha(alpha) end)

-- Events -----------------------------------------------------------------------

local handlers = {
    PLAYER_ENTERING_WORLD = UpdateAll,
    UNIT_PET = UpdateAll,
    PET_UI_UPDATE = UpdateAll,
    UNIT_NAME_UPDATE = UpdateName,
    UNIT_HAPPINESS = UpdateHappiness,
    UNIT_HEALTH = UpdateHealth,
    UNIT_MAXHEALTH = UpdateHealth,
    UNIT_HEAL_PREDICTION = UpdateHealth,
    UNIT_DISPLAYPOWER = function()
        UpdatePowerType()
        UpdatePower()
    end,
    UNIT_POWER_FREQUENT = UpdatePower,
    UNIT_MAXPOWER = UpdatePower,
}

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterUnitEvent("UNIT_PET", "player")
pcall(events.RegisterEvent, events, "PET_UI_UPDATE")
pcall(events.RegisterEvent, events, "UNIT_HAPPINESS")
for _, event in ipairs({ "UNIT_NAME_UPDATE", "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_HEAL_PREDICTION",
    "UNIT_DISPLAYPOWER", "UNIT_POWER_FREQUENT", "UNIT_MAXPOWER" }) do
    events:RegisterUnitEvent(event, "pet")
end

events:SetScript("OnEvent", function(_, event)
    if PetExists() then handlers[event]() end
end)

-- Settings ---------------------------------------------------------------------

ns.Watch("pet", "enabled", function(on)
    if on then return end
    events:UnregisterAllEvents()
    ns.AfterCombat(function()
        UnregisterUnitWatch(f)
        f:Hide()
    end)
end)
ns.Watch("pet", "scale", function() ns.AfterCombat(Place) end)
ns.Watch("player", "scale", function() ns.AfterCombat(Place) end)

-- Blizzard's PetFrame is a child of PlayerFrame, so it's already hidden with it.
