-- HoheUI core: the 1080-unit canvas every frame is laid out on, the palette,
-- and helpers for bars and text that may be handed secret values.
local _, ns = ...

ns.FONT_TEXT = STANDARD_TEXT_FONT
ns.FONT_NUMBER = "Fonts\\ARIALN.TTF"
ns.TEXTURE = "Interface\\Buttons\\WHITE8X8"

local function rgb(hex)
    return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255 }
end

ns.COLORS = {
    text = rgb("F5F7FA"),
    muted = rgb("98A2AE"),
    friendly = rgb("34D27A"),
    heal = rgb("8CF5B0"),
    hostile = rgb("F0443A"),
    neutral = rgb("F2C94C"),
    tapped = rgb("7D8590"),
    accent = rgb("FFC53D"),
    mana = rgb("3B82F6"),
    manaText = rgb("7FB2FF"),
    rage = rgb("E5484D"),
    energy = rgb("F5D547"),
    focus = rgb("F08A4B"),
    deficit = rgb("FF9F5A"),
    magic = rgb("3F8CFF"),
    curse = rgb("B24DFF"),
    disease = rgb("C8902E"),
    poison = rgb("3CB83C"),
    renew = rgb("FFF1A8"),
    rejuvenation = rgb("FF5FC8"),
    regrowth = rgb("3EE6D8"),
    xp = rgb("9B7BFF"),
    rested = rgb("4FA3FF"),
}

-- Where the player frame's top sits, in canvas units under the centre. The
-- party column, raid grid and pet frame are placed from it too. Below the
-- player frame there's room for Blizzard's utility and buff cooldown rows.
ns.PLAYER_TOP = -150
ns.UNDER_PLAYER = 84

local POWER = Enum and Enum.PowerType or {}
ns.POWER_MANA = POWER.Mana or 0
ns.POWER_RAGE = POWER.Rage or 1
ns.POWER_COLORS = {
    [ns.POWER_MANA] = ns.COLORS.mana,
    [ns.POWER_RAGE] = ns.COLORS.rage,
    [POWER.Focus or 2] = ns.COLORS.focus,
    [POWER.Energy or 3] = ns.COLORS.energy,
}

-- Secret values can be handed to the game, but never read or compared.
function ns.IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

-- The canvas ------------------------------------------------------------------
-- A full-screen frame scaled so it is always 1080 units tall: positions and
-- sizes are written in the design's 1080p pixels.
local root = CreateFrame("Frame", "HoheUIRoot", UIParent)
root:SetFrameStrata("LOW")
ns.root = root

-- Protected party buttons hang off the canvas, so it only changes out of combat.
local function Rescale()
    if InCombatLockdown() then return end
    root:SetScale(UIParent:GetHeight() / 1080)
    root:ClearAllPoints()
    root:SetAllPoints(UIParent)
end
Rescale()

-- Widgets ---------------------------------------------------------------------

-- The look: flat dark slate, a crisp black edge around every bar and panel,
-- and outlined text so it reads over any background.
ns.PANEL = { 0.055, 0.06, 0.075, 0.82 }
ns.TRACK = { 0.10, 0.11, 0.13, 0.9 }
-- Health bars invert it: a near-black fill over a near-white track, so
-- missing health shows as a bright gap.
ns.HEALTH_FILL = { 0.07, 0.07, 0.08 }
ns.HEALTH_TRACK = { 0.90, 0.91, 0.92, 1 }

function ns.CreateText(parent, size, font, color)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(font or ns.FONT_TEXT, size, "OUTLINE")
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.5)
    color = color or ns.COLORS.text
    fs:SetTextColor(color[1], color[2], color[3])
    return fs
end

-- A 1-unit black edge just outside `anchor`, drawn on `parent` so it sits
-- behind the anchor and shows and hides with the parent.
local function CreateEdge(parent, anchor, layer, sublevel)
    local edge = parent:CreateTexture(nil, layer, nil, sublevel)
    edge:SetPoint("TOPLEFT", anchor, "TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(0, 0, 0, 1)
    return edge
end

-- A dark backdrop with an edge, behind everything on `frame`.
function ns.CreatePanel(frame)
    CreateEdge(frame, frame, "BACKGROUND", -8)
    local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAllPoints()
    bg:SetColorTexture(ns.PANEL[1], ns.PANEL[2], ns.PANEL[3], ns.PANEL[4])
end

function ns.CreateBar(parent, height, color)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetHeight(height)
    bar:SetStatusBarTexture(ns.TEXTURE)
    color = color or ns.COLORS.text
    bar:SetStatusBarColor(color[1], color[2], color[3])
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(ns.TRACK[1], ns.TRACK[2], ns.TRACK[3], ns.TRACK[4])
    bar.track = track
    -- On the parent, because overlays make the bar clip what's outside it.
    CreateEdge(parent, bar, "BORDER")
    return bar
end

function ns.CreateHealthBar(parent, height)
    local bar = ns.CreateBar(parent, height, ns.HEALTH_FILL)
    local t = ns.HEALTH_TRACK
    bar.track:SetColorTexture(t[1], t[2], t[3], t[4])
    return bar
end

-- Text drawn over a bar, above anything overlaid on it.
function ns.CreateBarText(bar, size, color, font)
    local layer = CreateFrame("Frame", nil, bar)
    layer:SetAllPoints()
    layer:SetFrameLevel(bar:GetFrameLevel() + 10)
    return ns.CreateText(layer, size, font or ns.FONT_NUMBER, color)
end

-- A whole number, secret or not. Always the same format, so it doesn't change
-- look when combat makes it secret.
function ns.SetNumber(fs, value)
    if not ns.IsSecret(value) and type(value) ~= "number" then
        fs:SetText("")
    elseif not pcall(fs.SetFormattedText, fs, "%d", value) then
        fs:SetText("")
    end
end

-- A unit's health as "64%"; the game formats it when it's secret.
function ns.SetHealthPercent(fs, unit)
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    if not ns.IsSecret(cur) and not ns.IsSecret(max) then
        if max and max > 0 then
            fs:SetFormattedText("%d%%", math.floor(cur / max * 100 + 0.5))
        else
            fs:SetText("")
        end
        return
    end
    local scale = CurveConstants and CurveConstants.ScaleTo100
    if UnitHealthPercent and scale then
        local ok, pct = pcall(UnitHealthPercent, unit, false, scale)
        if ok and pcall(fs.SetFormattedText, fs, "%.0f%%", pct) then return end
    end
    fs:SetText("")
end

-- An overlay bar the same size as `bar`, starting where `texture` ends (or,
-- reversed, ending where it starts). Handed an amount out of `bar`'s maximum,
-- it marks that much past the fill without the addon doing any arithmetic.
function ns.CreateOverlay(bar, texture, color, alpha, reverse)
    local overlay = CreateFrame("StatusBar", nil, bar)
    overlay:SetStatusBarTexture(ns.TEXTURE)
    overlay:SetStatusBarColor(color[1], color[2], color[3], alpha)
    overlay:SetReverseFill(reverse == true)
    overlay:SetMinMaxValues(0, 1)
    overlay:SetValue(0)
    -- Vertical bars fill bottom to top, so "past the end" is above.
    local vertical = bar:GetOrientation() == "VERTICAL"
    overlay:SetOrientation(vertical and "VERTICAL" or "HORIZONTAL")
    local startPoint, endPoint = "LEFT", "RIGHT"
    if vertical then startPoint, endPoint = "BOTTOM", "TOP" end
    if reverse then
        overlay:SetPoint(endPoint, texture, startPoint)
    else
        overlay:SetPoint(startPoint, texture, endPoint)
    end
    overlay:SetSize(bar:GetSize())
    bar:HookScript("OnSizeChanged", function(_, width, height) overlay:SetSize(width, height) end)
    -- Anything past the bar's ends is cut off.
    bar:SetClipsChildren(true)
    return overlay
end

-- Incoming heals past the end of a health bar's fill: yours, then everyone
-- else's. The game's calculator clamps them to missing health.
function ns.CreateHealPrediction(healthBar, reverse)
    if not (CreateUnitHealPredictionCalculator and UnitGetDetailedHealPrediction) then return nil end
    local calc = CreateUnitHealPredictionCalculator()
    local clamp = Enum.UnitIncomingHealClampMode
    if clamp then calc:SetIncomingHealClampMode(clamp.MissingHealth) end
    calc:SetIncomingHealOverflowPercent(1)
    local fill = healthBar:GetStatusBarTexture()
    -- Translucent, so the heals read as dimmer than the solid health fill.
    local mine = ns.CreateOverlay(healthBar, fill, ns.COLORS.friendly, 0.85, reverse)
    local others = ns.CreateOverlay(healthBar, mine:GetStatusBarTexture(), ns.COLORS.friendly, 0.45, reverse)
    -- A dark line where current health ends, drawn over the heals.
    local divider = mine:CreateTexture(nil, "OVERLAY")
    divider:SetColorTexture(0, 0, 0, 0.9)
    local vertical = healthBar:GetOrientation() == "VERTICAL"
    if vertical then
        local edge = reverse and "BOTTOM" or "TOP"
        divider:SetPoint(edge .. "LEFT", fill, edge .. "LEFT")
        divider:SetPoint(edge .. "RIGHT", fill, edge .. "RIGHT")
        divider:SetHeight(2)
    else
        local edge = reverse and "LEFT" or "RIGHT"
        divider:SetPoint("TOP" .. edge, fill, "TOP" .. edge)
        divider:SetPoint("BOTTOM" .. edge, fill, "BOTTOM" .. edge)
        divider:SetWidth(2)
    end
    return { calc = calc, mine = mine, others = others }
end

function ns.UpdateHealPrediction(prediction, unit)
    if not prediction then return end
    local calc = prediction.calc
    UnitGetDetailedHealPrediction(unit, "player", calc)
    local max = calc:GetMaximumHealth()
    local _, mine, others = calc:GetIncomingHeals()
    prediction.mine:SetMinMaxValues(0, max)
    prediction.mine:SetValue(mine)
    prediction.others:SetMinMaxValues(0, max)
    prediction.others:SetValue(others)
end

function ns.ClearHealPrediction(prediction)
    if not prediction then return end
    prediction.mine:SetValue(0)
    prediction.others:SetValue(0)
end

function ns.Fade(frame, alpha)
    if math.abs(frame:GetAlpha() - alpha) < 0.01 then return end
    if UIFrameFadeIn then
        UIFrameFadeIn(frame, 0.25, frame:GetAlpha(), alpha)
    else
        frame:SetAlpha(alpha)
    end
end

-- Combat ---------------------------------------------------------------------------
-- Protected frames can't be shown, hidden, moved or resized in combat, so
-- changes to them wait for it to end. A function queued twice runs once.
local afterCombat = {}

function ns.AfterCombat(fn)
    if InCombatLockdown() then
        afterCombat[fn] = true
    else
        fn()
    end
end

local function RunAfterCombat()
    for fn in pairs(afterCombat) do
        afterCombat[fn] = nil
        fn()
    end
end

-- Blizzard's frames ------------------------------------------------------------
-- Moved under a hidden parent, not destroyed, so nothing that looks them up
-- breaks. They're protected, so this waits until combat is over. A frame
-- given with a settings page stays when that page's part is turned off.
local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()
local toHide = {}

function ns.HideBlizzard(frame, sectionKey)
    if frame then toHide[#toHide + 1] = { frame = frame, section = sectionKey } end
end

local function HidePending()
    if InCombatLockdown() then return end
    for i = #toHide, 1, -1 do
        local entry = toHide[i]
        if not entry.section or ns.Settings(entry.section).enabled then
            entry.frame:UnregisterAllEvents()
            entry.frame:SetParent(hiddenParent)
        end
        toHide[i] = nil
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("UI_SCALE_CHANGED")
events:RegisterEvent("DISPLAY_SIZE_CHANGED")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" or event == "PLAYER_REGEN_ENABLED" then
        HidePending()
        RunAfterCombat()
    end
    Rescale()
end)
