-- Player frame: centred under your character. A thick health bar with the
-- number inside it, a power bar beneath (and a thin mana bar under it while a
-- druid is in a form without mana), and two hairlines: the five-second
-- rule on the left, the swing timer on the right. A tag after the name says
-- when you're in combat or resting. Fades back when there's nothing to tell:
-- out of combat, no target, health and power full.
local _, ns = ...

local C = ns.COLORS
local IsSecret = ns.IsSecret

local FIVE_SECONDS = 5
local WIDTH = 300
local HALF = (WIDTH - 8) / 2

local db = ns.AddOptions("player", {
    { key = "enabled", kind = "toggle", label = "Player frame", default = true, reload = true,
      hint = "Off brings back Blizzard's player frame." },
    { key = "scale", kind = "range", label = "Size", default = 1, min = 0.5, max = 2, step = 0.05, percent = true },
    { key = "fade", kind = "toggle", label = "Fade when idle", default = true,
      hint = "Out of combat, no target, health and power full." },
    { key = "idleAlpha", kind = "range", label = "Faded opacity", default = 0.2, min = 0, max = 1, step = 0.05, percent = true },
    { key = "five", kind = "toggle", label = "Five-second rule", default = true },
    { key = "swing", kind = "toggle", label = "Swing timer", default = true },
})

local f = CreateFrame("Frame", "HoheUIPlayer", ns.root)
f:SetSize(WIDTH, 72)
ns.player = f

-- Grows from its top centre, which stays put.
local function Place()
    f:SetScale(db.scale)
    f:ClearAllPoints()
    f:SetPoint("TOP", ns.root, "CENTER", 0, ns.PLAYER_TOP / db.scale)
end
Place()

f.name = ns.CreateText(f, 13, ns.FONT_TEXT, C.muted)
f.name:SetPoint("TOP", f, "TOP", 0, 0)

f.state = ns.CreateText(f, 11, ns.FONT_NUMBER, C.muted)
f.state:SetPoint("LEFT", f.name, "RIGHT", 6, 0)

f.healthBar = ns.CreateHealthBar(f, 24)
f.healthBar:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -20)
f.healthBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -20)

f.powerBar = ns.CreateBar(f, 12, C.mana)
f.powerBar:SetPoint("TOPLEFT", f.healthBar, "BOTTOMLEFT", 0, -4)
f.powerBar:SetPoint("TOPRIGHT", f.healthBar, "BOTTOMRIGHT", 0, -4)

-- Incoming heals past the health fill; the cost of the spell being cast as a
-- pale band over the end of the power fill.
f.healPrediction = ns.CreateHealPrediction(f.healthBar)
f.cost = ns.CreateOverlay(f.powerBar, f.powerBar:GetStatusBarTexture(), C.text, 0.45, true)
f.cost:ClearAllPoints()
f.cost:SetPoint("RIGHT", f.powerBar:GetStatusBarTexture(), "RIGHT")

f.health = ns.CreateBarText(f.healthBar, 18, C.text)
f.health:SetPoint("CENTER", f.healthBar, "CENTER", 0, 0)

f.power = ns.CreateBarText(f.powerBar, 12, C.text)
f.power:SetPoint("CENTER", f.powerBar, "CENTER", 0, 0)

-- A druid's mana while shapeshifted, the number outside its left end.
f.manaGroup = CreateFrame("Frame", nil, f)
f.manaGroup:SetAllPoints()
f.manaGroup:Hide()
f.manaBar = ns.CreateBar(f.manaGroup, 6, C.mana)
f.manaBar:SetPoint("TOPLEFT", f.powerBar, "BOTTOMLEFT", 0, -4)
f.manaBar:SetPoint("TOPRIGHT", f.powerBar, "BOTTOMRIGHT", 0, -4)
f.mana = ns.CreateText(f.manaGroup, 11, ns.FONT_NUMBER, C.manaText)
f.mana:SetPoint("RIGHT", f.manaBar, "LEFT", -6, 0)

-- Five-second rule (left half), in its own group so it can hide for classes
-- without mana, and swing timer (right half). Labels sit outside the ends.
f.fiveGroup = CreateFrame("Frame", nil, f)
f.fiveGroup:SetAllPoints()
f.five = ns.CreateBar(f.fiveGroup, 4, C.manaText)
f.five:SetWidth(HALF)
f.fiveLabel = ns.CreateText(f.fiveGroup, 11, ns.FONT_NUMBER, C.muted)
f.fiveLabel:SetText("5s")
f.fiveLabel:SetPoint("RIGHT", f.five, "LEFT", -6, 0)

f.swingGroup = CreateFrame("Frame", nil, f)
f.swingGroup:SetAllPoints()
f.swing = ns.CreateBar(f.swingGroup, 4, C.text)
f.swing:SetWidth(HALF)
f.swingLabel = ns.CreateText(f.swingGroup, 11, ns.FONT_NUMBER, C.muted)
f.swingLabel:SetText("swing")
f.swingLabel:SetPoint("LEFT", f.swing, "RIGHT", 6, 0)

-- The hairlines sit under the lowest bar shown.
local function PlaceTimers(above)
    f.five:ClearAllPoints()
    f.five:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -6)
    f.swing:ClearAllPoints()
    f.swing:SetPoint("TOPRIGHT", above, "BOTTOMRIGHT", 0, -6)
end
PlaceTimers(f.powerBar)

-- Values -----------------------------------------------------------------------

local function UpdateName()
    f.name:SetFormattedText("%s · %d", UnitName("player"), UnitLevel("player"))
end

-- Combat wins over resting: you can be pulled into a fight in an inn.
local function UpdateState()
    local color
    if UnitAffectingCombat("player") then
        f.state:SetText("COMBAT")
        color = C.hostile
    elseif IsResting() then
        f.state:SetText("RESTING")
        color = C.manaText
    else
        f.state:SetText("")
        return
    end
    f.state:SetTextColor(color[1], color[2], color[3])
end

local function UpdateHealth()
    local cur, max = UnitHealth("player"), UnitHealthMax("player")
    f.healthBar:SetMinMaxValues(0, max)
    f.healthBar:SetValue(cur)
    ns.SetNumber(f.health, cur)
    ns.UpdateHealPrediction(f.healPrediction, "player")
end

local IS_DRUID = select(2, UnitClass("player")) == "DRUID"

local function UsesMana()
    local kind = UnitPowerType("player")
    return not IsSecret(kind) and kind == ns.POWER_MANA
end

-- A druid in bear or cat form still has mana underneath.
local function ShowsDruidMana()
    local kind = UnitPowerType("player")
    return IS_DRUID and not IsSecret(kind) and kind ~= ns.POWER_MANA
end

-- Whether mana matters right now, for the five-second rule.
local function HasMana()
    return UsesMana() or ShowsDruidMana()
end

local function UpdatePowerType()
    local kind = UnitPowerType("player")
    local color = not IsSecret(kind) and ns.POWER_COLORS[kind] or C.mana
    f.powerBar:SetStatusBarColor(color[1], color[2], color[3])
    local druidMana = ShowsDruidMana()
    f.manaGroup:SetShown(druidMana)
    PlaceTimers(druidMana and f.manaBar or f.powerBar)
    f.fiveGroup:SetShown(db.five and HasMana())
end

local function UpdatePower()
    local cur, max = UnitPower("player"), UnitPowerMax("player")
    f.powerBar:SetMinMaxValues(0, max)
    f.powerBar:SetValue(cur)
    ns.SetNumber(f.power, cur)
    if f.manaGroup:IsShown() then
        local mana = UnitPower("player", ns.POWER_MANA)
        f.manaBar:SetMinMaxValues(0, UnitPowerMax("player", ns.POWER_MANA))
        f.manaBar:SetValue(mana)
        ns.SetNumber(f.mana, mana)
    end
end

-- Fading -----------------------------------------------------------------------
-- Only decided out of combat, where nothing is secret; anything unreadable
-- counts as worth showing. A hurt pet keeps the frame lit too (the pet frame
-- follows this one's fade).

local function PetHurt()
    local exists = UnitExists("pet")
    if IsSecret(exists) then return true end
    if not exists then return false end
    local hp, hpMax = UnitHealth("pet"), UnitHealthMax("pet")
    if IsSecret(hp) or IsSecret(hpMax) then return true end
    return hp < hpMax
end

local function Idle()
    if UnitAffectingCombat("player") or UnitExists("target") then return false end
    local hp, hpMax = UnitHealth("player"), UnitHealthMax("player")
    local p, pMax = UnitPower("player"), UnitPowerMax("player")
    local kind = UnitPowerType("player")
    if IsSecret(hp) or IsSecret(hpMax) or IsSecret(p) or IsSecret(pMax) or IsSecret(kind) then return false end
    if hp < hpMax or PetHurt() then return false end
    if ShowsDruidMana() then
        local m, mMax = UnitPower("player", ns.POWER_MANA), UnitPowerMax("player", ns.POWER_MANA)
        if IsSecret(m) or IsSecret(mMax) or m < mMax then return false end
    end
    if kind == ns.POWER_RAGE then return p == 0 end
    return p >= pMax
end

local function UpdateAlpha()
    ns.Fade(f, db.fade and Idle() and db.idleAlpha or 1)
end
ns.UpdatePlayerAlpha = UpdateAlpha

-- Timers -----------------------------------------------------------------------

local fiveUntil -- when mana regen resumes after the last mana spent
local swingTotal, swingFinish -- the current main hand or ranged swing

-- What a spell costs in one power type, or 0 when it can't be told.
local function SpellCost(spellID, powerType)
    if IsSecret(spellID) or not spellID or IsSecret(powerType) then return 0 end
    local get = (C_Spell and C_Spell.GetSpellPowerCost) or GetSpellPowerCost
    if not get then return 0 end
    local ok, costs = pcall(get, spellID)
    if not ok or IsSecret(costs) or type(costs) ~= "table" then return 0 end
    for _, cost in ipairs(costs) do
        local kind, amount = cost.type, cost.cost
        if not IsSecret(kind) and not IsSecret(amount) and kind == powerType then
            return amount or 0
        end
    end
    return 0
end

local function ShowCost(spellID)
    local cost = SpellCost(spellID, UnitPowerType("player"))
    if cost > 0 then
        f.cost:SetMinMaxValues(0, UnitPowerMax("player"))
        f.cost:SetValue(cost)
    else
        f.cost:SetValue(0)
    end
end

local function OnUpdate()
    local now = GetTime()
    local active = false

    if fiveUntil and now < fiveUntil then
        f.five:SetValue((fiveUntil - now) / FIVE_SECONDS)
        active = true
    else
        fiveUntil = nil
        f.five:SetValue(0)
    end

    if swingFinish then
        local left = swingFinish - now
        f.swing:SetValue(left > 0 and 1 - left / swingTotal or 1)
        active = active or left > 0
    else
        f.swing:SetValue(0)
    end

    if not active then f:SetScript("OnUpdate", nil) end
end

local function Wake()
    f:SetScript("OnUpdate", OnUpdate)
end

-- PLAYER_SWING: seconds until the next swing, and which hand (0 main hand,
-- 1 off hand, 2 ranged). Off-hand swings and secret ones are skipped.
local function OnSwing(duration, kind)
    if IsSecret(duration) or IsSecret(kind) then return end
    if (kind ~= 0 and kind ~= 2) or type(duration) ~= "number" or duration <= 0 or duration > 60 then return end
    swingTotal, swingFinish = duration, GetTime() + duration
    Wake()
end

-- Events -----------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_UPDATE_RESTING")
events:RegisterUnitEvent("UNIT_HEALTH", "player")
events:RegisterUnitEvent("UNIT_MAXHEALTH", "player")
events:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
events:RegisterUnitEvent("UNIT_MAXPOWER", "player")
events:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player")
events:RegisterUnitEvent("UNIT_HEAL_PREDICTION", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
pcall(events.RegisterEvent, events, "PLAYER_SWING")
events:RegisterEvent("PLAYER_LEAVE_COMBAT")
events:RegisterEvent("STOP_AUTOREPEAT_SPELL")

events:SetScript("OnEvent", function(_, event, ...)
    if event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        UpdateHealth()
        UpdateAlpha()
    elseif event == "UNIT_POWER_FREQUENT" or event == "UNIT_MAXPOWER" then
        UpdatePower()
        UpdateAlpha()
    elseif event == "UNIT_HEAL_PREDICTION" then
        ns.UpdateHealPrediction(f.healPrediction, "player")
    elseif event == "UNIT_DISPLAYPOWER" then
        f.cost:SetValue(0)
        UpdatePowerType()
        UpdatePower()
    elseif event == "UNIT_SPELLCAST_START" then
        local _, _, spellID = ...
        ShowCost(spellID)
    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
        f.cost:SetValue(0)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        if HasMana() and SpellCost(spellID, ns.POWER_MANA) > 0 then
            fiveUntil = GetTime() + FIVE_SECONDS
            Wake()
        end
    elseif event == "PLAYER_SWING" then
        OnSwing(...)
    elseif event == "PLAYER_LEAVE_COMBAT" or event == "STOP_AUTOREPEAT_SPELL" then
        swingTotal, swingFinish = nil, nil
        f.swing:SetValue(0)
    elseif event == "PLAYER_LEVEL_UP" then
        UpdateName()
    elseif event == "PLAYER_UPDATE_RESTING" then
        UpdateState()
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        UpdateState()
        UpdateAlpha()
    elseif event == "PLAYER_TARGET_CHANGED" then
        UpdateAlpha()
    else -- PLAYER_ENTERING_WORLD
        UpdateName()
        UpdateState()
        UpdateHealth()
        UpdatePowerType()
        UpdatePower()
        UpdateAlpha()
    end
end)

-- Settings ---------------------------------------------------------------------

ns.Watch("player", "enabled", function(on)
    if on then return end
    events:UnregisterAllEvents()
    f:Hide()
end)
ns.Watch("player", "scale", Place)
ns.Watch("player", "fade", UpdateAlpha)
ns.Watch("player", "idleAlpha", UpdateAlpha)
ns.Watch("player", "five", function(on) f.fiveGroup:SetShown(on and HasMana()) end)
ns.Watch("player", "swing", function(on) f.swingGroup:SetShown(on) end)

ns.HideBlizzard(PlayerFrame, "player")
