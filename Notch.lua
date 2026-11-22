-- Notch: a black tab that grows out of the top of the screen to report what
-- just happened: a level, quest progress, experience, reputation, a
-- profession skill-up, money, loot and fish caught. On a Mac with a notch it starts at the notch's exact size and place,
-- so it reads as the notch expanding. Anything that happens in combat waits
-- until combat ends, so a fight is reported once, as a recap. Moving the
-- mouse onto the notch opens it with your XP. /hohenotch previews it.
local _, ns = ...

local C = ns.COLORS
local IsSecret = ns.IsSecret
local Comma = BreakUpLargeNumbers or tostring

local OPEN_WIDTH = 360
local FALLBACK_WIDTH = 180 -- no notch: grows out of the top edge from this wide
local RADIUS = 16
local PAD = 16
local PAD_TOP = 8
local PAD_BOTTOM = 14
local ROW_GAP = 8
local BAR_ROW_HEIGHT = 26
local LEVEL_ROW_HEIGHT = 24
local LINE_HEIGHT = 16
local MAX_LINES = 4
local GEAR_SIZE = 12
local LOOT_QUALITY = Enum and Enum.ItemQuality and Enum.ItemQuality.Uncommon or 2
local MAIN_HAND = INVSLOT_MAINHAND or 16
local WEAPON = Enum and Enum.ItemClass and Enum.ItemClass.Weapon or 2
local FISHING_POLE = Enum and Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Fishingpole or 20

-- Timeline, in seconds from the moment it's triggered.
local OPEN = 0.45
local FILL_DELAY = 0.3
local FILL = 0.9
local HOLD = 4
local HOLD_LEVEL = 6
local LINGER = 1 -- after the mouse leaves
local ZONE_MARGIN = 20 -- the hover zone reaches this far past each side of the notch
local ZONE_MIN_HEIGHT = 10
local CLOSE = 0.35

local db = ns.AddOptions("notch", {
    { key = "enabled", kind = "toggle", label = "Notch", default = true, reload = true,
      hint = "Off brings back Blizzard's experience and reputation bars." },
    { key = "peek", kind = "toggle", label = "Open on hover", default = true,
      hint = "Moving the mouse onto the notch shows your XP." },
    { kind = "header", label = "Report" },
    { key = "level", kind = "toggle", label = "Levels", default = true },
    { key = "quest", kind = "toggle", label = "Quest progress", default = true },
    { key = "xp", kind = "toggle", label = "Experience", default = true },
    { key = "rep", kind = "toggle", label = "Reputation", default = true },
    { key = "skill", kind = "toggle", label = "Profession skill-ups", default = true },
    { key = "money", kind = "toggle", label = "Money", default = true },
    { key = "loot", kind = "toggle", label = "Loot", default = true, hint = "Uncommon and better." },
    { key = "catch", kind = "toggle", label = "Fish caught", default = true },
})
ns.AddOptions("binds", {
    { key = "notch", kind = "bind", label = "Show the notch", default = false, click = "HoheUINotchPeek",
      needs = "notch", hint = "Your XP and watched reputation." },
})

local f = CreateFrame("Frame", "HoheUINotch", ns.root)
f:SetFrameStrata("HIGH")
f:SetClipsChildren(true)
f:SetMouseMotionEnabled(true) -- hovering it keeps it open; clicks go through
f:SetMouseClickEnabled(false)
f:Hide()

-- The shape ----------------------------------------------------------------------
-- Pure black so it merges with the notch: a body, a strip between the bottom
-- corners, and a circle in each bottom corner.

local function Black()
    local tex = f:CreateTexture(nil, "BACKGROUND")
    tex:SetColorTexture(0, 0, 0, 1)
    return tex
end

local body, base = Black(), Black()
local corners = {}
for i, side in ipairs({ "LEFT", "RIGHT" }) do
    local corner = f:CreateTexture(nil, "BACKGROUND")
    corner:SetTexture(ns.TEXTURE)
    corner:SetVertexColor(0, 0, 0, 1)
    corner:SetPoint("BOTTOM" .. side)
    local mask = f:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(corner)
    corner:AddMaskTexture(mask)
    corners[i] = corner
end

-- The corners shrink with the shape, so nothing turns inside out near zero.
local function SetShape(w, h)
    f:SetSize(math.max(w, 1), math.max(h, 1))
    local r = math.max(math.min(RADIUS, w / 2, h / 2), 0)
    body:SetPoint("TOPLEFT")
    body:SetPoint("BOTTOMRIGHT", 0, r)
    base:SetPoint("BOTTOMLEFT", r, 0)
    base:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -r, r)
    for _, corner in ipairs(corners) do corner:SetSize(math.max(r * 2, 0.01), math.max(r * 2, 0.01)) end
end

-- Where the notch is, in this frame's units: width, height, and its centre's
-- offset from the screen's centre. The client reports it in physical pixels.
local function NotchGeometry()
    local ui = C_UI
    if ui and ui.DoesAnyDisplayHaveNotch and ui.DoesAnyDisplayHaveNotch() and GetPhysicalScreenSize then
        local _, notchLeft, _, notchBottom = ui.GetTopLeftNotchSafeRegion()
        local notchRight = ui.GetTopRightNotchSafeRegion()
        local physW, physH = GetPhysicalScreenSize()
        if notchRight > notchLeft and notchBottom > 0 and physH > 0 then
            local units = WorldFrame:GetHeight() * WorldFrame:GetEffectiveScale() / physH / f:GetEffectiveScale()
            return (notchRight - notchLeft) * units, notchBottom * units, ((notchLeft + notchRight) - physW) / 2 * units
        end
    end
    return FALLBACK_WIDTH, 0, 0
end

-- An invisible zone over the notch that opens it on hover.
local zone = CreateFrame("Frame", nil, ns.root)
zone:SetFrameStrata("HIGH")
zone:SetMouseMotionEnabled(true)
zone:SetMouseClickEnabled(false)
f:SetFrameLevel(zone:GetFrameLevel() + 5)

local notchW, notchH, notchX = FALLBACK_WIDTH, 0, 0

local function PlaceNotch()
    notchW, notchH, notchX = NotchGeometry()
    zone:SetSize(notchW + ZONE_MARGIN * 2, math.max(notchH, ZONE_MIN_HEIGHT))
    zone:ClearAllPoints()
    zone:SetPoint("TOP", WorldFrame, "TOP", notchX, 0)
end

-- Rows -------------------------------------------------------------------------------
-- Laid out at the open size and revealed as the shape grows around them. Each
-- row has a key into the pending gains and Fill(data, open): data is nil when
-- the row is only staying open, and an open row adds to what it shows. Fill
-- returns the row's height, or nil to stay hidden. Rows with a bar also have
-- Animate(progress) and animate from row.from to row.to.

local content = CreateFrame("Frame", nil, f)
content:SetPoint("TOP")

-- A small gear in the top right corner, beside the notch, that opens the settings.
local gear = CreateFrame("Button", nil, content)
gear:SetSize(GEAR_SIZE + 8, GEAR_SIZE + 8) -- a little larger than the icon, to be easy to hit
gear:RegisterForClicks("LeftButtonUp")
gear.icon = gear:CreateTexture(nil, "ARTWORK")
gear.icon:SetSize(GEAR_SIZE, GEAR_SIZE)
gear.icon:SetPoint("CENTER")
if not gear.icon:SetAtlas("QuestLog-icon-setting") then
    gear.icon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
end
gear.icon:SetDesaturated(true)

local function TintGear(color, alpha)
    gear.icon:SetVertexColor(color[1], color[2], color[3], alpha)
end
TintGear(C.muted, 0.6)

gear:SetScript("OnClick", function() ns.ToggleOptions() end)

local function CreateRow(key)
    local row = CreateFrame("Frame", nil, content)
    row.key = key
    row.lines = {}
    row:Hide()
    return row
end

-- Line i of a row: text on the left (after an icon, if given), a note on the right.
local function SetLine(row, i, text, color, note, noteColor, icon)
    local line = row.lines[i]
    if not line then
        line = CreateFrame("Frame", nil, row)
        line:SetHeight(LINE_HEIGHT)
        line:SetPoint("TOPLEFT", 0, -(i - 1) * LINE_HEIGHT)
        line:SetPoint("TOPRIGHT", 0, -(i - 1) * LINE_HEIGHT)
        line.icon = line:CreateTexture(nil, "ARTWORK")
        line.icon:SetSize(14, 14)
        line.icon:SetPoint("LEFT")
        line.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        line.note = ns.CreateText(line, 12, ns.FONT_NUMBER)
        line.note:SetPoint("RIGHT")
        line.text = ns.CreateText(line, 12, ns.FONT_TEXT)
        line.text:SetPoint("RIGHT", line.note, "LEFT", -8, 0)
        line.text:SetJustifyH("LEFT")
        line.text:SetWordWrap(false)
        row.lines[i] = line
    end
    line.icon:SetShown(icon ~= nil)
    line.icon:SetTexture(icon)
    line.text:SetPoint("LEFT", icon and 20 or 0, 0)
    line.text:SetText(text)
    line.text:SetTextColor(color[1], color[2], color[3])
    noteColor = noteColor or C.muted
    line.note:SetText(note or "")
    line.note:SetTextColor(noteColor[1], noteColor[2], noteColor[3])
    line:Show()
end

-- Hides the lines past n and returns the row's height.
local function EndLines(row, n)
    for i = n + 1, #row.lines do row.lines[i]:Hide() end
    return n > 0 and n * LINE_HEIGHT or nil
end

local function CreateBarRow(key, color)
    local row = CreateRow(key)
    row.label = ns.CreateText(row, 12, ns.FONT_TEXT, C.text)
    row.label:SetPoint("TOPLEFT")
    row.gain = ns.CreateText(row, 12, ns.FONT_NUMBER, C.accent)
    row.gain:SetPoint("TOPRIGHT")
    row.bar = ns.CreateBar(row, 8, color)
    row.bar:SetPoint("BOTTOMLEFT")
    row.bar:SetPoint("BOTTOMRIGHT")
    function row:Animate(p)
        self.bar:SetValue(self.from + (self.to - self.from) * p)
    end
    return row
end

-- A running total while the row stays open; nil if no amount was ever known.
local function AddTotal(row, gain, open)
    if not open then row.total = nil end
    if gain then row.total = (row.total or 0) + gain end
    return row.total
end

-- Level: the new level, big, and what it brought.
-- data = { level, health, mana, talents }
local levelRow = CreateRow("level")
levelRow.title = ns.CreateText(levelRow, 20, ns.FONT_TEXT, C.accent)
levelRow.title:SetPoint("LEFT")
levelRow.note = ns.CreateText(levelRow, 12, ns.FONT_NUMBER, C.muted)
levelRow.note:SetPoint("RIGHT")

function levelRow:Fill(data, open)
    if not data then return open and LEVEL_ROW_HEIGHT or nil end
    self.title:SetFormattedText("Level %d", data.level)
    local parts = {}
    if data.health > 0 then parts[#parts + 1] = "+" .. Comma(data.health) .. " health" end
    if data.mana > 0 then parts[#parts + 1] = "+" .. Comma(data.mana) .. " mana" end
    if data.talents == 1 then
        parts[#parts + 1] = "1 talent point"
    elseif data.talents > 1 then
        parts[#parts + 1] = data.talents .. " talent points"
    end
    self.note:SetText(table.concat(parts, " · "))
    return LEVEL_ROW_HEIGHT
end

-- Quests: the objectives that moved, or "ready" once a quest is complete.
-- data = { order = { questID, ... }, objectives = { [questID] = { [index] = true } } }
local quests -- questID -> { title, counts, complete }, from the last scan
local questRow = CreateRow("quest")

function questRow:Fill(data, open)
    if not open then self.order, self.objectives = {}, {} end
    for _, id in ipairs(data and data.order or {}) do
        if not self.objectives[id] then
            self.objectives[id] = {}
            self.order[#self.order + 1] = id
        end
        for index in pairs(data.objectives[id]) do self.objectives[id][index] = true end
    end
    local n = 0
    for _, id in ipairs(self.order) do
        local quest = quests and quests[id]
        if quest and quest.complete then
            if n == MAX_LINES then break end
            n = n + 1
            SetLine(self, n, quest.title, C.friendly, "ready", C.friendly)
        elseif quest then
            local objectives = C_QuestLog.GetQuestObjectives(id) or {}
            for index, objective in ipairs(objectives) do
                if self.objectives[id][index] and n < MAX_LINES then
                    n = n + 1
                    SetLine(self, n, objective.text, objective.finished and C.friendly or C.text)
                end
            end
        end
    end
    return EndLines(self, n)
end

-- Experience, with rested XP as a band past the fill.
-- data = { gain, old, wrapped }
local xpRow = CreateBarRow("xp", C.xp)
xpRow.rested = ns.CreateOverlay(xpRow.bar, xpRow.bar:GetStatusBarTexture(), C.rested, 0.5)

function xpRow:Fill(data, open)
    local xp, max = UnitXP("player"), UnitXPMax("player")
    if IsSecret(xp) or IsSecret(max) or not max or max <= 0 then return nil end
    local old = data and data.old
    if open then old = self.bar:GetValue() end
    if data and data.wrapped then old = 0 end
    local total = AddTotal(self, data and data.gain, open)
    local rested = GetXPExhaustion and GetXPExhaustion() or 0
    if IsSecret(rested) then rested = 0 end
    local label = string.format("Level %d · %d%%", UnitLevel("player"), math.floor(xp / max * 100))
    -- Rested XP as a share of a whole level, in the band's colour.
    if rested > 0 then
        local c = C.rested
        local hex = string.format("%02x%02x%02x", c[1] * 255 + 0.5, c[2] * 255 + 0.5, c[3] * 255 + 0.5)
        label = string.format("%s · |cff%s%d%% rested|r", label, hex, math.floor(rested / max * 100))
    end
    self.label:SetText(label)
    self.gain:SetText(total and ("+" .. Comma(total) .. " XP") or "")
    self.bar:SetMinMaxValues(0, max)
    self.rested:SetMinMaxValues(0, max)
    self.rested:SetValue(rested)
    self.from, self.to = math.min(old or xp, xp), xp
    return BAR_ROW_HEIGHT
end

-- Reputation with the faction that just went up, in its standing's colour.
-- data = { id, gain, old }
local repRow = CreateBarRow("rep", C.friendly)

function repRow:Fill(data, open)
    local id = data and data.id or self.id
    local faction = id and C_Reputation and C_Reputation.GetFactionDataByID(id)
    if not faction or IsSecret(faction.currentStanding) then return nil end
    local low, high, standing = faction.currentReactionThreshold, faction.nextReactionThreshold, faction.currentStanding
    open = open and self.id == id
    local old = data and data.old
    if open then old = self.low + self.bar:GetValue() end
    local total = AddTotal(self, data and data.gain, open)
    self.id, self.low = id, low
    self.label:SetFormattedText("%s · %s", faction.name, _G["FACTION_STANDING_LABEL" .. faction.reaction] or "")
    self.gain:SetText(total and ("+" .. Comma(total) .. " rep") or "")
    local color = FACTION_BAR_COLORS and FACTION_BAR_COLORS[faction.reaction]
    if color then self.bar:SetStatusBarColor(color.r, color.g, color.b) end
    local span = high > low and high - low or 1
    self.bar:SetMinMaxValues(0, span)
    self.from = math.max(math.min((old or low) - low, span), 0)
    self.to = high > low and standing - low or span
    return BAR_ROW_HEIGHT
end

-- A profession that went up, on a bar to its current cap.
-- data = { line, gain, old }
local skills = {} -- skillLine -> { name, rank, max }, from the last scan
local skillRow = CreateBarRow("skill", C.neutral)

function skillRow:Fill(data, open)
    local line = data and data.line or self.line
    local skill = line and skills[line]
    if not skill then return nil end
    open = open and self.line == line
    local old = data and data.old
    if open then old = self.bar:GetValue() end
    local total = AddTotal(self, data and data.gain, open)
    self.line = line
    self.label:SetFormattedText("%s · %d / %d", skill.name, skill.rank, skill.max)
    self.gain:SetText(total and ("+" .. total .. " skill") or "")
    self.bar:SetMinMaxValues(0, math.max(skill.max, 1))
    self.from, self.to = math.min(old or skill.rank, skill.rank), skill.rank
    return BAR_ROW_HEIGHT
end

-- Money gained (spending isn't shown). data = copper
local function Coins(copper)
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        return C_CurrencyInfo.GetCoinTextureString(copper, 12)
    end
    return GetMoneyString and GetMoneyString(copper) or Comma(copper)
end

local moneyRow = CreateRow("money")

function moneyRow:Fill(data, open)
    local total = AddTotal(self, data, open)
    if not total or total <= 0 then return nil end
    SetLine(self, 1, "Money", C.muted, "+" .. Coins(total), C.accent)
    return EndLines(self, 1)
end

-- Adds items to a row's list, one entry per link, kept while the row stays open.
-- data = { { link, count }, ... }
local function AddItems(row, data, open)
    if not open then row.items = {} end
    for _, item in ipairs(data or {}) do
        local merged = false
        for _, have in ipairs(row.items) do
            if have.link == item.link then
                have.count = have.count + item.count
                merged = true
                break
            end
        end
        if not merged then row.items[#row.items + 1] = { link = item.link, id = item.id, count = item.count } end
    end
end

-- Lists a row's items, note(item) on the right; the last line counts the rest.
local function ItemLines(row, note)
    local n = math.min(#row.items, MAX_LINES)
    for i = 1, n do
        local item = row.items[i]
        local icon = C_Item and C_Item.GetItemIconByID(item.link)
        local text = note(item)
        if i == MAX_LINES and #row.items > MAX_LINES then text = "+" .. (#row.items - MAX_LINES + 1) .. " more" end
        SetLine(row, i, item.link, C.text, text, C.muted, icon)
    end
    return EndLines(row, n)
end

-- Uncommon or better items received.
local lootRow = CreateRow("loot")

function lootRow:Fill(data, open)
    AddItems(self, data, open)
    return ItemLines(self, function(item) return item.count > 1 and ("x" .. item.count) or nil end)
end

-- Anything looted with a fishing pole in hand, any quality, and how many of
-- it were caught since the pole went on.
local catches = {} -- itemID -> count since the main hand last changed
local catchRow = CreateRow("catch")

function catchRow:Fill(data, open)
    AddItems(self, data, open)
    return ItemLines(self, function(item)
        return string.format("+%d · %d total", item.count, catches[item.id] or item.count)
    end)
end

-- Top to bottom.
local ROWS = { levelRow, questRow, xpRow, repRow, skillRow, moneyRow, catchRow, lootRow }

-- Animation ------------------------------------------------------------------------

local anim -- nil while closed
local hovered = false

local function Clamp(p) return p < 0 and 0 or (p > 1 and 1 or p) end
local function EaseOut(p) return 1 - (1 - p) ^ 3 end
-- Overshoots a little and settles, for the opening.
local function EaseBack(p) return 1 + 2.2 * (p - 1) ^ 3 + 1.2 * (p - 1) ^ 2 end

local function OnUpdate(_, elapsed)
    anim.t = anim.t + elapsed
    -- The mouse holds it open, but not into combat.
    if hovered and not InCombatLockdown() and anim.t < anim.closeAt then
        anim.closeAt = math.max(anim.closeAt, anim.t + LINGER)
    end
    local t, closeAt = anim.t, anim.closeAt
    local w, h, alpha
    if t < closeAt then
        local p = EaseBack(Clamp(t / OPEN))
        w = anim.fromW + (anim.toW - anim.fromW) * p
        h = anim.fromH + (anim.toH - anim.fromH) * p
        alpha = anim.fromAlpha + (1 - anim.fromAlpha) * Clamp((t - OPEN / 2) / (OPEN / 2))
    else
        -- Closing starts from wherever it is, even if combat cut the opening short.
        if not anim.closeW then anim.closeW, anim.closeH, anim.closeAlpha = anim.w, anim.h, anim.alpha end
        local p = EaseOut(Clamp((t - closeAt) / CLOSE))
        w = anim.closeW + (notchW - anim.closeW) * p
        h = anim.closeH + (notchH - anim.closeH) * p
        alpha = anim.closeAlpha * (1 - Clamp((t - closeAt) / (CLOSE / 2)))
    end
    anim.w, anim.h, anim.alpha = w, h, alpha
    SetShape(w, h)
    content:SetAlpha(alpha)

    local fill = EaseOut(Clamp((t - FILL_DELAY) / FILL))
    for _, row in ipairs(ROWS) do
        if row.Animate and row:IsShown() then row:Animate(fill) end
    end

    if t >= closeAt + CLOSE then
        anim = nil
        f:SetScript("OnUpdate", nil)
        f:Hide()
        for _, row in ipairs(ROWS) do row:Hide() end
    end
end

-- Gains, keyed like the rows, collected until they can be shown. An amount
-- the addon couldn't tell is nil.
local pending = {}

local function Present()
    if InCombatLockdown() then return end
    -- Rows turned off in the settings (the settings keys are the row keys).
    for _, row in ipairs(ROWS) do
        if not db[row.key] then pending[row.key] = nil end
    end
    if not next(pending) then return end
    local gains = pending
    pending = {}

    PlaceNotch()
    local width = math.max(OPEN_WIDTH, notchW + RADIUS * 2 + 40)
    -- The gear sits beside the notch, or in a short band of its own without one.
    local top = math.max(notchH, GEAR_SIZE + 8)
    gear:ClearAllPoints()
    gear:SetPoint("CENTER", content, "TOPRIGHT", -PAD - GEAR_SIZE / 2, -top / 2)
    local y = top + PAD_TOP
    local any = false
    for _, row in ipairs(ROWS) do
        local open = anim ~= nil and row:IsShown()
        local height
        if gains[row.key] ~= nil or open then height = row:Fill(gains[row.key], open) end
        row:SetShown(height ~= nil)
        if height then
            any = true
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
            row:SetSize(width - PAD * 2, height)
            if row.Animate then row:Animate(0) end
            y = y + height + ROW_GAP
        end
    end
    if not any then return end
    local height = y - ROW_GAP + PAD_BOTTOM
    content:SetSize(width, height)
    f:ClearAllPoints()
    f:SetPoint("TOP", WorldFrame, "TOP", notchX, 0)

    -- Start from wherever the shape is now: the notch if closed, else its size.
    local fromW, fromH, fromAlpha = notchW, notchH, 0
    if anim then fromW, fromH, fromAlpha = anim.w, anim.h, anim.alpha end
    anim = {
        t = 0, closeAt = OPEN + (gains.level and HOLD_LEVEL or HOLD),
        fromW = fromW, fromH = fromH, fromAlpha = fromAlpha, toW = width, toH = height,
        w = fromW, h = fromH, alpha = fromAlpha,
    }
    SetShape(fromW, fromH)
    content:SetAlpha(fromAlpha)
    f:Show()
    f:SetScript("OnUpdate", OnUpdate)
end

-- Hovering opens it with your XP and the watched faction, unless it's already
-- showing another faction's gain. Not in combat.
local function Peek()
    if InCombatLockdown() then return end
    pending.xp = pending.xp or {}
    local watched = not repRow:IsShown() and C_Reputation and C_Reputation.GetWatchedFactionData()
    if watched then pending.rep = pending.rep or { id = watched.factionID } end
    Present()
end

local function UpdateHover()
    hovered = zone:IsMouseOver() or (f:IsShown() and f:IsMouseOver())
end

zone:SetScript("OnEnter", function()
    if not db.peek then return end
    hovered = true
    Peek()
end)
zone:SetScript("OnLeave", UpdateHover)
f:SetScript("OnEnter", function() hovered = true end)
f:SetScript("OnLeave", UpdateHover)
gear:SetScript("OnEnter", function()
    hovered = true
    TintGear(C.text, 1)
end)
gear:SetScript("OnLeave", function()
    TintGear(C.muted, 0.6)
    UpdateHover()
end)

-- A number from an event payload, or 0 when it's missing or secret.
local function Amount(value)
    if IsSecret(value) or type(value) ~= "number" then return 0 end
    return value
end

local function OnLevel(level, health, power, talents)
    if IsSecret(level) or not level then return end
    local p = pending.level or { health = 0, mana = 0, talents = 0 }
    p.level = level
    p.health = p.health + Amount(health)
    -- Only mana users gain maximum power with a level.
    local kind = UnitPowerType("player")
    if not IsSecret(kind) and kind == ns.POWER_MANA then p.mana = p.mana + Amount(power) end
    p.talents = p.talents + Amount(talents)
    pending.level = p
    Present()
end

-- XP falling means a level was crossed: the gain is the rest of the old level
-- plus what's in the new one.
local lastXP, lastXPMax

local function OnXP()
    local xp, max = UnitXP("player"), UnitXPMax("player")
    if IsSecret(xp) or IsSecret(max) then return end
    if lastXP and xp ~= lastXP then
        local p = pending.xp or { gain = 0, old = lastXP }
        if xp < lastXP then
            p.gain = p.gain and p.gain + (lastXPMax - lastXP) + xp
            p.wrapped = true
        else
            p.gain = p.gain and p.gain + xp - lastXP
        end
        pending.xp = p
        Present()
    end
    lastXP, lastXPMax = xp, max
end

-- Reputation. Losses are recorded but not shown; a faction never seen before
-- shows without an amount.
local standings = {} -- factionID -> last standing seen

local function SnapshotFactions()
    if not (C_Reputation and C_Reputation.GetNumFactions) then return end
    for i = 1, C_Reputation.GetNumFactions() do
        local data = C_Reputation.GetFactionDataByIndex(i)
        if data and data.factionID and not IsSecret(data.currentStanding) then
            standings[data.factionID] = data.currentStanding
        end
    end
end

local function OnStanding(id, standing)
    if IsSecret(id) or IsSecret(standing) or not id or not standing then return end
    local old = standings[id]
    standings[id] = standing
    if old and standing <= old then return end
    local p = pending.rep
    if p and p.id == id then
        p.gain = p.gain and old and p.gain + standing - old
    else
        pending.rep = { id = id, gain = old and standing - old, old = old }
    end
    Present()
end

local lastMoney

local function OnMoney()
    local money = GetMoney()
    if IsSecret(money) then return end
    if lastMoney and money > lastMoney then
        pending.money = (pending.money or 0) + money - lastMoney
        Present()
    end
    lastMoney = money
end

-- Professions: each scan compares ranks with the last one. A profession seen
-- for the first time (just learnt, or the first scan) is only recorded.
local function ScanSkills()
    if not (GetProfessions and GetProfessionInfo) then return end
    for _, index in pairs({ GetProfessions() }) do
        local name, _, rank, max, _, _, line = GetProfessionInfo(index)
        if line and not IsSecret(rank) and not IsSecret(max) and type(rank) == "number" then
            local old = skills[line] and skills[line].rank
            skills[line] = { name = name, rank = rank, max = max or rank }
            if old and rank > old then
                local p = pending.skill
                if p and p.line == line then
                    p.gain = (p.gain or 0) + rank - old
                else
                    pending.skill = { line = line, gain = rank - old, old = old }
                end
                Present()
            end
        end
    end
end

-- Fishing: whether the main hand holds a pole. Any change of main hand
-- starts the catch counts over.
local fishing = false

local function HoldingPole()
    local id = GetInventoryItemID("player", MAIN_HAND)
    if not (id and C_Item and C_Item.GetItemInfoInstant) then return false end
    local _, _, _, _, _, class, subclass = C_Item.GetItemInfoInstant(id)
    return class == WEAPON and subclass == FISHING_POLE
end

-- Loot: the chat line for an item you received, turned into a pattern that
-- captures the link and, for stacks, the count.
local function LootPattern(format)
    if type(format) ~= "string" then return nil end
    local pattern = format:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    pattern = pattern:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
    return "^" .. pattern .. "$"
end

-- Stacks first: the single-item patterns would match them too. Pushed items
-- (quest rewards and the like) are never a catch.
local LOOT_PATTERNS = {}
for _, format in ipairs({ LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF_MULTIPLE, LOOT_ITEM_SELF, LOOT_ITEM_PUSHED_SELF }) do
    local pattern = LootPattern(format)
    if pattern then
        LOOT_PATTERNS[#LOOT_PATTERNS + 1] = { pattern = pattern, pushed = format == LOOT_ITEM_PUSHED_SELF_MULTIPLE or format == LOOT_ITEM_PUSHED_SELF }
    end
end

local function OnLoot(text)
    if IsSecret(text) or type(text) ~= "string" then return end
    for _, loot in ipairs(LOOT_PATTERNS) do
        local link, count = text:match(loot.pattern)
        if link then
            count = tonumber(count) or 1
            local id = tonumber(link:match("item:(%d+)"))
            if fishing and id and not loot.pushed then
                catches[id] = (catches[id] or 0) + count
                pending.catch = pending.catch or {}
                table.insert(pending.catch, { link = link, id = id, count = count })
                Present()
                return
            end
            -- Unknown quality (not cached yet) is shown rather than dropped.
            local quality = C_Item and C_Item.GetItemQualityByID(link)
            if quality and quality < LOOT_QUALITY then return end
            pending.loot = pending.loot or {}
            table.insert(pending.loot, { link = link, count = count })
            Present()
            return
        end
    end
end

-- Quests: each scan compares objective counts with the last one. Quests seen
-- for the first time (just accepted, or the first scan) are only recorded.
local function AddQuest(id, index)
    local p = pending.quest or { order = {}, objectives = {} }
    pending.quest = p
    if not p.objectives[id] then
        p.objectives[id] = {}
        p.order[#p.order + 1] = id
    end
    if index then p.objectives[id][index] = true end
end

local function ScanQuests()
    local log = C_QuestLog
    if not (log and log.GetNumQuestLogEntries) then return end
    local seen = {}
    for i = 1, log.GetNumQuestLogEntries() do
        local info = log.GetInfo(i)
        local id = info and not info.isHeader and not info.isHidden and info.questID
        if id then
            local counts = {}
            for index, objective in ipairs(log.GetQuestObjectives(id) or {}) do
                if IsSecret(objective.numFulfilled) then return end
                counts[index] = objective.numFulfilled
            end
            local complete = log.IsComplete(id)
            if IsSecret(complete) then return end
            local known = quests and quests[id]
            if known then
                for index, count in ipairs(counts) do
                    if count > (known.counts[index] or 0) then AddQuest(id, index) end
                end
                if complete and not known.complete then AddQuest(id) end
            end
            seen[id] = { title = info.title, counts = counts, complete = complete }
        end
    end
    quests = seen
end

-- Events ----------------------------------------------------------------------------

local handlers = {
    PLAYER_ENTERING_WORLD = function()
        lastXP, lastXPMax = UnitXP("player"), UnitXPMax("player")
        if IsSecret(lastXP) or IsSecret(lastXPMax) then lastXP, lastXPMax = nil, nil end
        lastMoney = GetMoney()
        if IsSecret(lastMoney) then lastMoney = nil end
        SnapshotFactions()
        ScanQuests()
        ScanSkills()
        fishing = HoldingPole()
        PlaceNotch()
    end,
    -- After Core has rescaled the canvas the zone is sized in.
    DISPLAY_SIZE_CHANGED = function() C_Timer.After(0, PlaceNotch) end,
    UI_SCALE_CHANGED = function() C_Timer.After(0, PlaceNotch) end,
    NOTCHED_DISPLAY_MODE_CHANGED = function() C_Timer.After(0, PlaceNotch) end,
    PLAYER_LEVEL_UP = OnLevel,
    PLAYER_XP_UPDATE = OnXP,
    FACTION_STANDING_CHANGED = OnStanding,
    PLAYER_MONEY = OnMoney,
    CHAT_MSG_LOOT = OnLoot,
    SKILL_LINES_CHANGED = ScanSkills,
    -- The rank may not be updated yet when the line is printed.
    CHAT_MSG_SKILL = function() C_Timer.After(0, ScanSkills) end,
    PLAYER_EQUIPMENT_CHANGED = function(slot)
        if slot ~= MAIN_HAND then return end
        fishing = HoldingPole()
        catches = {}
    end,
    QUEST_LOG_UPDATE = function()
        ScanQuests()
        Present()
    end,
    PLAYER_REGEN_ENABLED = function()
        ScanQuests()
        Present()
    end,
    PLAYER_REGEN_DISABLED = function()
        if anim and anim.t < anim.closeAt then anim.t = anim.closeAt end
    end,
}

local events = CreateFrame("Frame")
for event in pairs(handlers) do pcall(events.RegisterEvent, events, event) end
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)

-- A preview with real data: up to two quests in the log, the current XP, the
-- watched faction and a profession, bars filling from empty.
SLASH_HOHENOTCH1 = "/hohenotch"
SlashCmdList.HOHENOTCH = function()
    if not db.enabled then return end
    local shown = 0
    for id, quest in pairs(quests or {}) do
        if shown == 2 then break end
        AddQuest(id)
        for index in ipairs(quest.counts) do AddQuest(id, index) end
        shown = shown + 1
    end
    pending.xp = { old = 0 }
    local watched = C_Reputation and C_Reputation.GetWatchedFactionData()
    if watched then pending.rep = { id = watched.factionID } end
    local line = next(skills)
    if line then pending.skill = { line = line, old = 0 } end
    Present()
end

ns.AddCommand("notch", "preview the notch", SlashCmdList.HOHENOTCH)

-- A key can open it too (see Binds.lua).
local peekButton = CreateFrame("Button", "HoheUINotchPeek", UIParent)
peekButton:SetScript("OnClick", Peek)

-- Settings ---------------------------------------------------------------------

ns.Watch("notch", "enabled", function(on)
    if on then return end
    events:UnregisterAllEvents()
    zone:Hide()
end)

-- Blizzard's experience and reputation bars: the notch shows both.
ns.HideBlizzard(StatusTrackingBarManager, "notch")
