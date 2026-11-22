-- Target frame: to the right of the player frame, its health bar level with
-- the player's. One thick dark-on-light health bar with the health percent
-- inside it; the name above in the target's colour (by reaction, grey when
-- tapped or dead), with level and rank coloured by difficulty; a thin power bar under it, and a
-- small target-of-target frame below that. Beside it, on the right, the
-- debuffs you put on the target (top row) and the buffs you put on it (below).
local _, ns = ...

local C = ns.COLORS
local IsSecret = ns.IsSecret

local RANKS = { elite = "+", rareelite = " rare+", rare = " rare", worldboss = " boss" }

local db = ns.AddOptions("target", {
    { key = "enabled", kind = "toggle", label = "Target frame", default = true, reload = true,
      hint = "Off brings back Blizzard's target frame." },
    { key = "scale", kind = "range", label = "Size", default = 1, min = 0.5, max = 2, step = 0.05, percent = true },
    { key = "tot", kind = "toggle", label = "Target of target", default = true },
    { key = "auras", kind = "toggle", label = "Your buffs and debuffs", default = true,
      hint = "Only the ones you cast on the target." },
})
local player = ns.Settings("player")

local f = CreateFrame("Frame", "HoheUITarget", ns.root)
f:SetSize(280, 70)
f:Hide()

-- 56 right of the player frame, health bars level whatever either's size.
local function Place()
    local scale = db.scale
    f:SetScale(scale)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", ns.player, "TOPRIGHT", 56 / scale, 20 * (scale - player.scale) / scale)
end
Place()

f.healthBar = ns.CreateHealthBar(f, 24)
f.healthBar:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -20)
f.healthBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -20)
f.healPrediction = ns.CreateHealPrediction(f.healthBar)

-- Mana, rage or energy, coloured by type. Hidden for units without power.
f.powerBar = ns.CreateBar(f, 8, C.mana)
f.powerBar:SetPoint("TOPLEFT", f.healthBar, "BOTTOMLEFT", 0, -4)
f.powerBar:SetPoint("TOPRIGHT", f.healthBar, "BOTTOMRIGHT", 0, -4)

f.percent = ns.CreateBarText(f.healthBar, 18, C.text)
f.percent:SetPoint("RIGHT", f.healthBar, "RIGHT", -6, 0)

f.level = ns.CreateText(f, 15, ns.FONT_NUMBER, C.muted)
f.level:SetPoint("BOTTOMRIGHT", f.healthBar, "TOPRIGHT", 0, 4)

f.name = ns.CreateText(f, 16, ns.FONT_TEXT, C.text)
f.name:SetPoint("BOTTOMLEFT", f.healthBar, "TOPLEFT", 0, 4)
f.name:SetPoint("RIGHT", f.level, "LEFT", -8, 0)
f.name:SetJustifyH("LEFT")
f.name:SetWordWrap(false)

-- Target of target: "→ Brakk" in its class or reaction colour ("→ You" when
-- it's you), over a thin health bar. Half the target frame's width.
local tot = CreateFrame("Frame", nil, f)
tot:SetSize(140, 30)
tot:SetPoint("TOPLEFT", f.powerBar, "BOTTOMLEFT", 0, -8)
tot:Hide()
f.tot = tot

tot.arrow = ns.CreateText(tot, 13, ns.FONT_TEXT, C.muted)
tot.arrow:SetText("→")
tot.arrow:SetPoint("TOPLEFT", tot, "TOPLEFT", 0, 0)
tot.name = ns.CreateText(tot, 13, ns.FONT_TEXT, C.text)
tot.name:SetPoint("LEFT", tot.arrow, "RIGHT", 4, 0)
tot.name:SetPoint("RIGHT", tot, "RIGHT", 0, 0)
tot.name:SetJustifyH("LEFT")
tot.name:SetWordWrap(false)

tot.healthBar = ns.CreateHealthBar(tot, 8)
tot.healthBar:SetPoint("BOTTOMLEFT", tot, "BOTTOMLEFT", 0, 0)
tot.healthBar:SetPoint("BOTTOMRIGHT", tot, "BOTTOMRIGHT", 0, 0)

-- Your auras on the target: two rows of icons right of the target of target,
-- growing from the right edge. Each row is one of Blizzard's aura containers,
-- which picks the auras, sets icon, timer swipe and stack count, and follows
-- the target by itself, so secret auras never reach this file.
local AURA_SIZE = 22
local AURA_GAP = 3
local AURA_MAX = 5 -- fits the half of the frame the target of target leaves

local function InitializeAura(edgeColor, button)
    button:SetSize(AURA_SIZE, AURA_SIZE)
    if button.SetMouseClickEnabled then button:SetMouseClickEnabled(false) end
    local edge = button:CreateTexture(nil, "BACKGROUND")
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(edgeColor[1], edgeColor[2], edgeColor[3], 1)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    cooldown:SetReverse(true)
    cooldown:SetDrawEdge(false)
    cooldown:SetDrawBling(false)
    if cooldown.SetUseAuraDisplayTime then cooldown:SetUseAuraDisplayTime(true) end
    cooldown:SetHideCountdownNumbers(false)
    local countdown = cooldown:GetRegions()
    if countdown and countdown.SetFont then
        countdown:SetFont(ns.FONT_NUMBER, 11, "OUTLINE")
        countdown:ClearAllPoints()
        countdown:SetPoint("CENTER")
    end
    local count = cooldown:CreateFontString(nil, "OVERLAY")
    count:SetFont(ns.FONT_NUMBER, 10, "OUTLINE")
    count:SetPoint("BOTTOMRIGHT", 2, -1)
    button:SetIcon(icon)
    button:SetDurationCooldown(cooldown)
    button:SetApplicationCount(count)
end

local function CreateAuraRow(filter, edgeColor)
    local container = CreateFrame("AuraContainer", nil, f, "CustomAuraContainerTemplate")
    container:SetSize(AURA_MAX * (AURA_SIZE + AURA_GAP) - AURA_GAP, AURA_SIZE)
    container:AddAuraGroup(filter, filter, {
        maxFrameCount = AURA_MAX,
        initializeFrame = GenerateClosure(InitializeAura, edgeColor),
        layout = { elementWidth = AURA_SIZE, elementHeight = AURA_SIZE, elementSpacing = AURA_GAP },
    })
    container:SetFlowLayoutAnchorPoint("TOPRIGHT")
    container:SetFlowLayoutGrowthDirection(AnchorUtil.FlowDirection.Left, AnchorUtil.FlowDirection.Down)
    container:SetUnit("target")
    return container
end

f.debuffs = CreateAuraRow("HARMFUL|PLAYER", C.hostile)
f.debuffs:SetPoint("TOPRIGHT", f.powerBar, "BOTTOMRIGHT", 0, -8)
f.buffs = CreateAuraRow("HELPFUL|PLAYER", C.friendly)
f.buffs:SetPoint("TOPRIGHT", f.debuffs, "BOTTOMRIGHT", 0, -AURA_GAP - 2)

-- Values -----------------------------------------------------------------------

local function Readable(...)
    for i = 1, select("#", ...) do
        if IsSecret((select(i, ...))) then return false end
    end
    return true
end

-- A player's class colour, or `fallback`.
local function ClassColor(unit, fallback)
    local isPlayer, class = UnitIsPlayer(unit), select(2, UnitClass(unit))
    if Readable(isPlayer, class) and isPlayer and class and RAID_CLASS_COLORS[class] then
        local cc = RAID_CLASS_COLORS[class]
        return { cc.r, cc.g, cc.b }
    end
    return fallback
end

local function HealthColor(unit)
    local tapped, dead = UnitIsTapDenied(unit), UnitIsDead(unit)
    local reaction = UnitReaction(unit, "player")
    if not Readable(tapped, dead, reaction) then return C.hostile end
    if tapped or dead then return C.tapped end
    if not reaction or reaction >= 5 then return C.friendly end
    if reaction == 4 then return C.neutral end
    return C.hostile
end

local function UpdateHealth()
    local cur, max = UnitHealth("target"), UnitHealthMax("target")
    f.healthBar:SetMinMaxValues(0, max)
    f.healthBar:SetValue(cur)
    -- Incoming heals only on friendly targets.
    local friendly = UnitIsFriend("player", "target")
    if Readable(friendly) and friendly then
        ns.UpdateHealPrediction(f.healPrediction, "target")
    else
        ns.ClearHealPrediction(f.healPrediction)
    end
    local dead = UnitIsDead("target")
    if Readable(dead) and dead then
        f.percent:SetText("Dead")
    else
        ns.SetHealthPercent(f.percent, "target")
    end
end

-- A secret maximum counts as having power.
local function UpdatePower()
    local cur, max = UnitPower("target"), UnitPowerMax("target")
    f.powerBar:SetShown(not Readable(max) or (max and max > 0))
    f.powerBar:SetMinMaxValues(0, max)
    f.powerBar:SetValue(cur)
end

local function UpdatePowerType()
    local kind = UnitPowerType("target")
    local color = Readable(kind) and ns.POWER_COLORS[kind] or C.mana
    f.powerBar:SetStatusBarColor(color[1], color[2], color[3])
end

local function UpdateLook()
    local color = HealthColor("target")
    f.name:SetTextColor(color[1], color[2], color[3])
end

-- The game's grey/green/yellow/orange/red for a level, where it has one.
local function DifficultyColor(level)
    if GetCreatureDifficultyColor then
        local ok, color = pcall(GetCreatureDifficultyColor, level)
        if ok and type(color) == "table" and color.r then return { color.r, color.g, color.b } end
    end
    return C.muted
end

local function UpdateName()
    f.name:SetText(UnitName("target"))
    local level, rank = UnitLevel("target"), UnitClassification("target")
    if Readable(level, rank) then
        local known = level and level > 0
        f.level:SetFormattedText("%s%s", known and tostring(level) or "??", RANKS[rank] or "")
        local color = known and DifficultyColor(level) or C.hostile
        f.level:SetTextColor(color[1], color[2], color[3])
    else
        f.level:SetText("")
    end
end

local function UpdateTargetOfTargetHealth()
    tot.healthBar:SetMinMaxValues(0, UnitHealthMax("targettarget"))
    tot.healthBar:SetValue(UnitHealth("targettarget"))
end

local function UpdateTargetOfTarget()
    local exists = UnitExists("targettarget")
    if not db.tot or not Readable(exists) or not exists then
        tot:Hide()
        return
    end
    local isMe = UnitIsUnit("targettarget", "player")
    local color
    if Readable(isMe) and isMe then
        tot.name:SetText("You")
        color = C.accent
    else
        tot.name:SetText(UnitName("targettarget"))
        color = ClassColor("targettarget", HealthColor("targettarget"))
    end
    tot.name:SetTextColor(color[1], color[2], color[3])
    UpdateTargetOfTargetHealth()
    tot:Show()
end

-- The game sends no unit events for "targettarget", so its health is read a
-- few times a second, only while it's shown.
local elapsedSinceHealth = 0
tot:SetScript("OnUpdate", function(_, elapsed)
    elapsedSinceHealth = elapsedSinceHealth + elapsed
    if elapsedSinceHealth < 0.2 then return end
    elapsedSinceHealth = 0
    UpdateTargetOfTargetHealth()
end)

-- The containers follow the target's auras; a new target needs a full read.
local function UpdateAuras()
    for _, row in ipairs({ f.debuffs, f.buffs }) do
        row:SetEnabled(db.auras)
        row:SetShown(db.auras)
        if db.auras then row:UpdateAllAuras() end
    end
end

local function UpdateAll()
    if not UnitExists("target") then
        f:Hide()
        return
    end
    UpdateName()
    UpdateLook()
    UpdateHealth()
    UpdatePowerType()
    UpdatePower()
    UpdateTargetOfTarget()
    UpdateAuras()
    f:Show()
end

-- Events -----------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterUnitEvent("UNIT_HEALTH", "target")
events:RegisterUnitEvent("UNIT_MAXHEALTH", "target")
events:RegisterUnitEvent("UNIT_HEAL_PREDICTION", "target")
events:RegisterUnitEvent("UNIT_POWER_FREQUENT", "target")
events:RegisterUnitEvent("UNIT_MAXPOWER", "target")
events:RegisterUnitEvent("UNIT_DISPLAYPOWER", "target")
events:RegisterUnitEvent("UNIT_NAME_UPDATE", "target")
events:RegisterUnitEvent("UNIT_LEVEL", "target")
events:RegisterUnitEvent("UNIT_FACTION", "target")
events:RegisterUnitEvent("UNIT_CLASSIFICATION_CHANGED", "target")
events:RegisterUnitEvent("UNIT_TARGET", "target")

events:SetScript("OnEvent", function(_, event)
    if not UnitExists("target") then
        f:Hide()
    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" or event == "UNIT_HEAL_PREDICTION" then
        UpdateHealth()
        UpdateLook()
    elseif event == "UNIT_POWER_FREQUENT" or event == "UNIT_MAXPOWER" then
        UpdatePower()
    elseif event == "UNIT_DISPLAYPOWER" then
        UpdatePowerType()
        UpdatePower()
    elseif event == "UNIT_TARGET" then
        UpdateTargetOfTarget()
    elseif event == "UNIT_FACTION" then
        UpdateLook()
    elseif event == "UNIT_NAME_UPDATE" or event == "UNIT_LEVEL" or event == "UNIT_CLASSIFICATION_CHANGED" then
        UpdateName()
    else
        UpdateAll()
    end
end)

-- Settings ---------------------------------------------------------------------

ns.Watch("target", "enabled", function(on)
    if on then return end
    events:UnregisterAllEvents()
    f.debuffs:SetEnabled(false)
    f.buffs:SetEnabled(false)
    f:Hide()
end)
ns.Watch("target", "scale", Place)
ns.Watch("player", "scale", Place)
ns.Watch("target", "tot", UpdateTargetOfTarget)
ns.Watch("target", "auras", UpdateAuras)

ns.HideBlizzard(TargetFrame, "target")
