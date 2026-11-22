-- Group tiles: the Grid-style member tiles the party column (Party.lua) and
-- the raid grid (Raid.lua) are built from. Each tile fills bottom to top,
-- near-black over near-white, with the name in the member's class colour and
-- a health text under it (the "healthText" setting: missing health "-1050"
-- while hurt, a percent, what's left, or nothing), incoming heals above the
-- fill, and a labelled band across the top for a debuff you can dispel.
-- A healer's tile gives its bottom strip to a mana bar.
-- Each HoT you cast is a small square of its own colour in its own corner,
-- draining as the HoT runs out.
--
-- A member's state takes the health text's place, brightly: Offline, Dead,
-- Ghost, then AFK. Offline, dead and ghost members step back (the tile goes
-- dark and dims, the name greys), but the state stays bright. One icon in the
-- middle shows, first come, a resurrection on its way, a summon, or the
-- member's ready check answer (kept a few seconds after the check ends).
-- One out of range dims.
--
-- The tiles show Controller Forever's healer pick (thick white border; see
-- Heal.lua), and a click picks a member; without a pick it targets them.
-- Shift-click always targets; your target gets a thin gold border. The
-- picked member's tile (or your target's, without a pick) grows a little.
--
-- Health and auras can be secret in combat, so the "is full" decision is
-- handed to the game as a curve, and the dispel band is drawn by the game's
-- own aura container (as Grid2 does); neither is read here.
--
-- A tile is made with ns.CreateTile(parent, unit, name, style, db): `style`
-- gives its sizes (see Party.lua), `db` the settings page whose "grow",
-- "hots", "dispel" and "mana" it follows.
local _, ns = ...

local C = ns.COLORS
local IsSecret = ns.IsSecret

local PICKED_SCALE = 1.12
local GROW_TIME = 0.15
local INACTIVE_ALPHA = 0.45 -- dead or offline
local OUT_OF_RANGE_ALPHA = 0.4
local DISPEL_FILTER = "HARMFUL|RAID" -- harmful auras you can dispel
-- Members without an assigned role count as healers by class.
local HEALER_CLASSES = { PRIEST = true, DRUID = true, SHAMAN = true, PALADIN = true }

-- Your HoTs, matched by name so every rank counts. `slot` 0 sits in the
-- corner, 1 next to it, towards the middle.
local HOT_FILTER = "HELPFUL|PLAYER"
local HOTS = {
    { spell = 139, color = C.renew, point = "BOTTOMLEFT", slot = 0 }, -- Renew
    { spell = 774, color = C.rejuvenation, point = "BOTTOMRIGHT", slot = 0 }, -- Rejuvenation
    { spell = 8936, color = C.regrowth, point = "BOTTOMRIGHT", slot = 1 }, -- Regrowth
}
local TIMER_REMAINING = Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.RemainingTime

-- Keyed by the game's dispel type names.
local DISPELS = {
    { name = "Magic", label = "MAGIC", color = C.magic },
    { name = "Curse", label = "CURSE", color = C.curse },
    { name = "Disease", label = "DISEASE", color = C.disease },
    { name = "Poison", label = "POISON", color = C.poison },
}

-- The "healthText" setting's choices (Party.lua, Raid.lua).
ns.HEALTH_TEXT_CHOICES = {
    { value = "none", text = "None" },
    { value = "lost", text = "Lost" },
    { value = "percent", text = "Percent" },
    { value = "remaining", text = "Remaining" },
}

-- What takes the health text's place. An inactive member steps back.
local OFFLINE = { text = "Offline", color = C.text, inactive = true }
local DEAD = { text = "Dead", color = C.hostile, inactive = true }
local GHOST = { text = "Ghost", color = C.hostile, inactive = true }
local AFK = { text = "AFK", color = C.neutral }

-- The middle icon.
local ICON_RES = { file = "Interface\\RaidFrame\\Raid-Icon-Rez" }
local ICONS_READY = {
    ready = { file = READY_CHECK_READY_TEXTURE or "Interface\\RaidFrame\\ReadyCheck-Ready" },
    notready = { file = READY_CHECK_NOT_READY_TEXTURE or "Interface\\RaidFrame\\ReadyCheck-NotReady" },
    waiting = { file = READY_CHECK_WAITING_TEXTURE or "Interface\\RaidFrame\\ReadyCheck-Waiting" },
}
local ICONS_SUMMON = {}
if Enum.SummonStatus then
    ICONS_SUMMON[Enum.SummonStatus.Pending] = { atlas = "Raid-Icon-SummonPending" }
    ICONS_SUMMON[Enum.SummonStatus.Accepted] = { atlas = "Raid-Icon-SummonAccepted" }
    ICONS_SUMMON[Enum.SummonStatus.Declined] = { atlas = "Raid-Icon-SummonDeclined" }
end
local READY_CHECK_LINGER = 10 -- seconds the answers stay after a check ends

-- Curves ------------------------------------------------------------------------

local function StepCurve(points)
    if not (C_CurveUtil and C_CurveUtil.CreateCurve and Enum.LuaCurveType) then return nil end
    local curve = C_CurveUtil.CreateCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    for _, point in ipairs(points) do curve:AddPoint(point[1], point[2]) end
    return curve
end

-- Anything above this is alive; exactly 0 is empty.
local ALIVE = 0.000001

-- An alpha for each of three health states: empty (0), hurt, exactly full.
-- The curve gives the same answer when health is secret.
local function HealthRule(empty, hurt, full)
    return {
        empty = empty, hurt = hurt, full = full,
        curve = StepCurve({ { 0, empty }, { ALIVE, hurt }, { 1, full } }),
    }
end

local LOST_TEXT = HealthRule(0, 1, 0) -- "-1050" only while hurt
local SHOWN_TEXT = HealthRule(0, 1, 1) -- percent or remaining, unless empty
-- When the game won't say whether a member is dead, empty health stands in.
local DEAD_LABEL = HealthRule(1, 0, 0)
local DEAD_BODY = HealthRule(INACTIVE_ALPHA, 1, 1)

-- The rule's alpha for readable health; otherwise the curve's (secret) answer.
local function ByHealth(unit, rule)
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    if not IsSecret(cur) and not IsSecret(max) then
        if not max or max <= 0 then return rule.full end
        if cur <= 0 then return rule.empty end
        return cur >= max and rule.full or rule.hurt
    end
    if rule.curve and UnitHealthPercent then
        local ok, value = pcall(UnitHealthPercent, unit, false, rule.curve)
        if ok then return value end
    end
    return rule.hurt
end

-- An alpha from a boolean that may be secret.
local function AlphaFromBoolean(region, value, whenTrue, whenFalse)
    if IsSecret(value) then
        if region.SetAlphaFromBoolean then pcall(region.SetAlphaFromBoolean, region, value, whenTrue, whenFalse) end
    else
        region:SetAlpha(value and whenTrue or whenFalse)
    end
end

-- Frames ------------------------------------------------------------------------

local tiles = {}

-- A square outline `inset` units inside the parent's edge.
local function CreateBorder(parent, size, color, inset)
    local border = CreateFrame("Frame", nil, parent)
    border:SetPoint("TOPLEFT", inset, -inset)
    border:SetPoint("BOTTOMRIGHT", -inset, inset)
    border:SetFrameLevel(parent:GetFrameLevel() + 20)
    local edges = {
        { "TOPLEFT", "TOPRIGHT", nil, size },
        { "BOTTOMLEFT", "BOTTOMRIGHT", nil, size },
        { "TOPLEFT", "BOTTOMLEFT", size, nil },
        { "TOPRIGHT", "BOTTOMRIGHT", size, nil },
    }
    for _, edge in ipairs(edges) do
        local tex = border:CreateTexture(nil, "OVERLAY")
        tex:SetColorTexture(color[1], color[2], color[3])
        tex:SetPoint(edge[1])
        tex:SetPoint(edge[2])
        if edge[3] then tex:SetWidth(edge[3]) else tex:SetHeight(edge[4]) end
    end
    border:SetAlpha(0)
    return border
end

-- The dispel band is a slot in one of Blizzard's aura containers, the way
-- Grid2 draws debuffs. The game picks the debuff, colours the band, writes
-- its label and shows or hides it, so secret auras never reach this file.
local function CreateDispelSlot(parent, unit, level, style)
    local colors, labels = {}, {}
    for _, dispel in ipairs(DISPELS) do
        colors[dispel.name] = CreateColor(dispel.color[1], dispel.color[2], dispel.color[3])
        labels[dispel.name] = dispel.label
    end
    local container = CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")
    container:SetPoint("TOPLEFT")
    container:SetPoint("TOPRIGHT")
    container:SetHeight(style.dispel)
    container:SetFrameLevel(level)
    container:AddAuraSlot("dispel", DISPEL_FILTER, {
        initializeFrame = function(band)
            band:EnableMouse(false) -- clicks belong to the tile
            band:ClearAllPoints()
            band:SetAllPoints(container)
            band:SetFrameLevel(level)
            local bg = band:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(1, 1, 1, 1)
            band:AddDispelTypeTexture(bg, {
                style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
                customDispelColorMap = colors,
            })
            local label = band:CreateFontString(nil, "OVERLAY")
            label:SetFont(ns.FONT_NUMBER, style.dispelText, "")
            label:SetTextColor(0.07, 0.07, 0.07)
            label:SetPoint("CENTER")
            band:SetDispelTypeText(label, { customDispelTextMap = labels })
        end,
    })
    container:SetUnit(unit)
    return container
end

-- One square per HoT, keyed by its HOTS entry, in the corners of `anchor`.
-- Each is a bar in a holder, so its edge hides with it.
local function CreateHotSquares(parent, anchor, level, style)
    local size, inset = style.hot, style.hotInset
    local squares = {}
    for _, hot in ipairs(HOTS) do
        local holder = CreateFrame("Frame", nil, parent)
        holder:SetSize(size, size)
        local x = inset + hot.slot * (size + style.hotGap)
        holder:SetPoint(hot.point, anchor, hot.point, hot.point == "BOTTOMRIGHT" and -x or x, inset)
        holder:SetFrameLevel(level)
        local bar = ns.CreateBar(holder, size, hot.color)
        bar:SetAllPoints()
        bar:SetOrientation("VERTICAL")
        holder.bar = bar
        holder:Hide()
        squares[hot] = holder
    end
    return squares
end

-- Values ------------------------------------------------------------------------

-- Class colour, or grey while the member is offline or dead.
local function ColorName(btn)
    local color = btn.inactive and C.muted or C.text
    local r, g, b = color[1], color[2], color[3]
    local _, class = UnitClass(btn.unit)
    if not btn.inactive and not IsSecret(class) and class and RAID_CLASS_COLORS[class] then
        local cc = RAID_CLASS_COLORS[class]
        r, g, b = cc.r, cc.g, cc.b
    end
    btn.name:SetTextColor(r, g, b)
end

local function UpdateName(btn)
    btn.name:SetText(UnitName(btn.unit))
    ColorName(btn)
end

-- A healer by assigned role or, without one, by class.
local function IsHealer(unit)
    local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
    if IsSecret(role) then role = nil end
    if role and role ~= "NONE" then return role == "HEALER" end
    local _, class = UnitClass(unit)
    return not IsSecret(class) and HEALER_CLASSES[class] == true
end

-- Always mana, even for a druid in a form.
local function UpdateMana(btn)
    if not btn.mana:IsShown() then return end
    btn.manaBar:SetMinMaxValues(0, UnitPowerMax(btn.unit, ns.POWER_MANA))
    btn.manaBar:SetValue(UnitPower(btn.unit, ns.POWER_MANA))
end

-- The health bar isn't protected, so this can run in combat.
local function UpdateManaShown(btn)
    local shown = btn.db.mana and IsHealer(btn.unit)
    if btn.mana:IsShown() ~= shown then
        btn.mana:SetShown(shown)
        btn.healthBar:ClearAllPoints()
        btn.healthBar:SetPoint("TOPLEFT")
        if shown then
            -- One unit above the strip, so the two edges make a dark line.
            btn.healthBar:SetPoint("BOTTOMRIGHT", btn.mana, "TOPRIGHT", 0, 1)
        else
            btn.healthBar:SetPoint("BOTTOMRIGHT")
        end
    end
    UpdateMana(btn)
end

-- True only when the game says so in a value that can be read.
local function IsTrue(value)
    return not IsSecret(value) and value == true
end

-- The member's state (OFFLINE, DEAD, GHOST, AFK) or nil while they're up.
-- The second value is true when the game kept death secret, so they may be
-- dead after all.
local function State(unit)
    local connected = UnitIsConnected(unit)
    if not IsSecret(connected) and connected == false then return OFFLINE end
    local ghost = UnitIsGhost and UnitIsGhost(unit)
    if IsTrue(ghost) then return GHOST end
    local dead = UnitIsDead(unit)
    if IsTrue(dead) then return DEAD end
    if UnitIsAFK and IsTrue(UnitIsAFK(unit)) then return AFK end
    return nil, IsSecret(dead) or IsSecret(ghost)
end

-- An offline or dead member's tile goes dark and dims.
local function SetInactive(btn, inactive)
    btn.inactive = inactive
    local track = inactive and ns.TRACK or ns.HEALTH_TRACK
    btn.healthBar.track:SetColorTexture(track[1], track[2], track[3], track[4])
    btn.body:SetAlpha(inactive and INACTIVE_ALPHA or 1)
    ColorName(btn)
end

local function ShowState(btn, state, alpha)
    btn.status:SetText(state.text)
    btn.status:SetTextColor(state.color[1], state.color[2], state.color[3])
    btn.status:SetAlpha(alpha)
    btn.status:Show()
end

-- "-1050", from the heal calculator when there is one, so it works secret.
local function SetLost(btn, cur, max)
    local fs, missing = btn.healthText, nil
    if btn.prediction then
        missing = btn.prediction.calc:GetMissingHealth()
    elseif not IsSecret(cur) and not IsSecret(max) then
        missing = max - cur
    end
    if (IsSecret(missing) or missing ~= nil) and pcall(fs.SetFormattedText, fs, "-%d", missing) then return end
    fs:SetText("")
end

local function SetHealthText(btn, cur, max)
    local fs, mode = btn.healthText, btn.db.healthText
    local color = mode == "lost" and C.deficit or C.text
    fs:SetTextColor(color[1], color[2], color[3])
    if mode == "lost" then
        SetLost(btn, cur, max)
    elseif mode == "percent" then
        ns.SetHealthPercent(fs, btn.unit)
    elseif mode == "remaining" then
        ns.SetNumber(fs, cur)
    else
        fs:SetText("")
    end
    fs:SetAlpha(ByHealth(btn.unit, mode == "lost" and LOST_TEXT or SHOWN_TEXT))
end

local function UpdateHealth(btn)
    local unit = btn.unit
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    btn.healthBar:SetMinMaxValues(0, max)
    btn.healthBar:SetValue(cur)
    ns.UpdateHealPrediction(btn.prediction, unit)

    local state, maybeDead = State(unit)
    SetInactive(btn, state ~= nil and state.inactive == true)
    if state then
        ShowState(btn, state, 1)
        btn.healthText:SetAlpha(0)
        return
    end

    SetHealthText(btn, cur, max)
    if maybeDead then
        -- Empty health reads as dead: the label shows and the body dims,
        -- both decided by the game.
        ShowState(btn, DEAD, ByHealth(unit, DEAD_LABEL))
        btn.body:SetAlpha(ByHealth(unit, DEAD_BODY))
    else
        btn.status:Hide()
    end
end

-- The middle icon -----------------------------------------------------------------

local readyCheckOver = false -- the check ended; answers linger
local readyCheckRound = 0

local function SummonIcon(unit)
    local summons = C_IncomingSummon
    if not (summons and summons.HasIncomingSummon and summons.IncomingSummonStatus) then return nil end
    if not IsTrue(summons.HasIncomingSummon(unit)) then return nil end
    local status = summons.IncomingSummonStatus(unit)
    return not IsSecret(status) and ICONS_SUMMON[status] or nil
end

-- The answer to the current check, or the last one while it lingers.
local function ReadyIcon(btn)
    if not readyCheckOver then
        local status = GetReadyCheckStatus and GetReadyCheckStatus(btn.unit)
        btn.readyStatus = not IsSecret(status) and status or nil
    end
    return btn.readyStatus and ICONS_READY[btn.readyStatus]
end

local function UpdateIcon(btn)
    local unit = btn.unit
    local ready = ReadyIcon(btn) -- read first, so its answer is kept even under another icon
    local icon
    if UnitHasIncomingResurrection and IsTrue(UnitHasIncomingResurrection(unit)) then
        icon = ICON_RES
    end
    icon = icon or SummonIcon(unit) or ready
    local tex = btn.icon
    if not icon then
        tex:Hide()
        return
    end
    if icon.atlas then
        tex:SetAtlas(icon.atlas)
    else
        tex:SetTexture(icon.file)
    end
    tex:Show()
end

-- The container follows its unit's auras by itself. This turns it on or off
-- and, after a roster change, has it read the auras of whoever is there now.
local function UpdateDispel(btn)
    local container, on = btn.dispel, btn.db.dispel
    container:SetEnabled(on)
    container:SetShown(on)
    if on then container:UpdateAllAuras() end
end

-- HoT names in the client's language, from the spell IDs above.
local hotsByName = {}

local function LearnHotNames()
    for _, hot in ipairs(HOTS) do
        local name = C_Spell.GetSpellName(hot.spell)
        if name then hotsByName[name] = hot end
    end
end
LearnHotNames()

-- Which HoT an aura is. Names can be secret in combat; an aura seen while
-- readable is remembered by its instance ID, which a refresh keeps.
local function HotOf(btn, unit, auraID, seen)
    local hot = btn.hotIDs[auraID]
    local ok, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, auraID)
    local name = ok and aura and aura.name
    if name and not IsSecret(name) then hot = hotsByName[name] or false end
    seen[auraID] = hot
    return hot
end

-- Drains the square over what's left of the aura; full if the game can't say.
local function ShowRemaining(square, unit, auraID)
    local bar = square.bar
    local getDuration = C_UnitAuras.GetAuraDuration
    if getDuration and bar.SetTimerDuration and TIMER_REMAINING then
        local ok, duration = pcall(getDuration, unit, auraID)
        if ok and duration and pcall(bar.SetTimerDuration, bar, duration, nil, TIMER_REMAINING) then
            square:Show()
            return
        end
    end
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    square:Show()
end

local function UpdateHots(btn)
    local unit, squares = btn.unit, btn.hots
    if not btn.db.hots then
        for _, square in pairs(squares) do square:Hide() end
        return
    end
    for _, square in pairs(squares) do square.found = false end
    local getIDs = C_UnitAuras and C_UnitAuras.GetUnitAuraInstanceIDs
    local ok, ids = false, nil
    if getIDs and C_UnitAuras.GetAuraDataByAuraInstanceID then ok, ids = pcall(getIDs, unit, HOT_FILTER) end
    local seen = {}
    if ok and type(ids) == "table" then
        for _, auraID in ipairs(ids) do
            local hot = not IsSecret(auraID) and HotOf(btn, unit, auraID, seen)
            local square = hot and squares[hot]
            if square and not square.found then
                square.found = true
                ShowRemaining(square, unit, auraID)
            end
        end
    end
    btn.hotIDs = seen
    for _, square in pairs(squares) do
        if not square.found then square:Hide() end
    end
end

-- HoT changes come per tile, registered for its own unit, the way
-- Blizzard's raid frames listen. A plain UNIT_AURA registration hears every
-- unit, and in combat it can't tell which, so it rescanned every tile on
-- every nameplate's aura change. A frame hears one event for at most two
-- units, so each tile gets its own small frame.
local function WatchAuras(btn)
    if not btn.auraEvents then
        btn.auraEvents = CreateFrame("Frame")
        btn.auraEvents:SetScript("OnEvent", function()
            if btn:IsVisible() then UpdateHots(btn) end
        end)
    end
    btn.auraEvents:RegisterUnitEvent("UNIT_AURA", btn.unit)
end

local function UpdateRange(btn)
    -- You're never out of range of yourself (previews show you in every tile).
    if btn.unit == "player" then
        btn:SetAlpha(1)
        return
    end
    local inRange, checked = UnitInRange(btn.unit)
    if not IsSecret(checked) and not checked then
        btn:SetAlpha(1)
        return
    end
    AlphaFromBoolean(btn, inRange, 1, OUT_OF_RANGE_ALPHA)
end

-- Grows or shrinks a tile's art to `scale` over GROW_TIME, easing out. The
-- picked tile is drawn over its neighbours.
local function Grow(art, elapsed)
    art.growTime = art.growTime + elapsed
    local t = math.min(art.growTime / GROW_TIME, 1)
    t = 1 - (1 - t) * (1 - t)
    art:SetScale(art.growFrom + (art.growTo - art.growFrom) * t)
    if t >= 1 then art:SetScript("OnUpdate", nil) end
end

local function GrowTo(art, scale)
    if art.growTo == scale then return end
    art.growFrom, art.growTo, art.growTime = art:GetScale(), scale, 0
    art:SetFrameStrata(scale > 1 and "MEDIUM" or "LOW")
    art:SetScript("OnUpdate", Grow)
end

-- True only when the game says so in a value that can be read.
local function SameUnit(unit, other)
    if unit == other then return true end
    local same = UnitIsUnit(unit, other)
    return not IsSecret(same) and same == true
end

local function UpdateSelected(btn)
    -- While the gyro pick button is held, the party tile it's on stands in
    -- for the pick (Arch.lua steps through the party column only).
    local aim = btn.aimable and ns.GetArchAim and ns.GetArchAim()
    local pick = ns.GetHealPick()
    if aim then
        btn.selectBorder:SetAlpha(aim == btn.index and 1 or 0)
    elseif pick then
        AlphaFromBoolean(btn.selectBorder, UnitIsUnit(btn.unit, pick), 1, 0)
    else
        btn.selectBorder:SetAlpha(0)
    end
    AlphaFromBoolean(btn.targetBorder, UnitIsUnit(btn.unit, "target"), 1, 0)

    local picked
    if aim then
        picked = aim == btn.index
    else
        picked = SameUnit(btn.unit, pick or "target")
    end
    GrowTo(btn.art, picked and btn.db.grow and PICKED_SCALE or 1)
end

local function UpdateAll(btn)
    if not UnitExists(btn.unit) then return end
    UpdateName(btn)
    UpdateManaShown(btn)
    UpdateHealth(btn)
    UpdateIcon(btn)
    UpdateDispel(btn)
    UpdateHots(btn)
    UpdateRange(btn)
    UpdateSelected(btn)
end
ns.UpdateTile = UpdateAll

function ns.CreateTile(parent, unit, name, style, db)
    local width, height = style.width, style.height
    local btn = CreateFrame("Button", name, parent, "SecureUnitButtonTemplate,SecureHandlerBaseTemplate")
    btn:SetSize(width, height)
    btn:SetAttribute("unit", unit)
    -- A plain click picks this member for healing (see Heal.lua) or,
    -- without a healer pick, targets them.
    btn:SetAttribute("type1", "target")
    btn:SetAttribute("shift-type1", "target")
    btn:SetAttribute("*type2", "togglemenu")
    btn:RegisterForClicks("AnyUp")
    btn.unit = unit
    btn.homeUnit = unit
    btn.db = db

    -- Everything drawn lives in `art`, which grows when the member is picked
    -- (the button is protected, so it can't change size in combat; `art`
    -- isn't). What steps back when dead or offline lives in `body`; range dimming
    -- is on the button itself, so the two multiply.
    local art = CreateFrame("Frame", nil, btn)
    art:SetSize(width, height)
    art:SetPoint("CENTER")
    btn.art = art

    local body = CreateFrame("Frame", nil, art)
    body:SetAllPoints()
    btn.body = body

    -- The whole tile is the health bar, or all but the mana strip for a
    -- healer (see UpdateManaShown). The strip is in a group so its edge
    -- hides with it.
    btn.mana = CreateFrame("Frame", nil, body)
    btn.mana:SetPoint("BOTTOMLEFT")
    btn.mana:SetPoint("BOTTOMRIGHT")
    btn.mana:SetHeight(style.mana)
    btn.mana:Hide()
    btn.manaBar = ns.CreateBar(btn.mana, style.mana, C.mana)
    btn.manaBar:SetAllPoints()

    btn.healthBar = ns.CreateHealthBar(body, height)
    btn.healthBar:SetOrientation("VERTICAL")
    btn.healthBar:SetAllPoints()
    btn.prediction = ns.CreateHealPrediction(btn.healthBar)

    btn.name = ns.CreateBarText(btn.healthBar, style.nameSize, C.text)
    btn.name:SetPoint("CENTER", 0, style.nameY)
    btn.name:SetWidth(width - 8)
    btn.name:SetWordWrap(false)

    btn.healthText = ns.CreateBarText(btn.healthBar, style.healthTextSize, C.deficit)
    btn.healthText:SetPoint("CENTER", 0, style.healthTextY)

    -- The state and the middle icon are on `art`, not the body, so they
    -- stay bright when the body steps back.
    local over = CreateFrame("Frame", nil, art)
    over:SetAllPoints(btn.healthBar)
    over:SetFrameLevel(btn.healthBar:GetFrameLevel() + 13)
    btn.status = ns.CreateText(over, style.statusSize, ns.FONT_NUMBER, C.text)
    btn.status:SetPoint("CENTER", 0, style.healthTextY)
    btn.status:Hide()
    btn.icon = over:CreateTexture(nil, "OVERLAY")
    btn.icon:SetSize(style.icon, style.icon)
    btn.icon:SetPoint("CENTER")
    btn.icon:Hide()

    -- On `art`, not the body, so it stays bright when the body steps back.
    btn.dispel = CreateDispelSlot(art, unit, btn.healthBar:GetFrameLevel() + 12, style)
    btn.hots = CreateHotSquares(art, btn.healthBar, btn.healthBar:GetFrameLevel() + 11, style)
    btn.hotIDs = {}

    -- Selected for healing outside, target inside it, so both can show.
    btn.selectBorder = CreateBorder(art, 3, C.text, 0)
    btn.targetBorder = CreateBorder(art, 2, C.accent, 4)

    ns.AddHealTile(btn)
    btn:HookScript("OnShow", UpdateAll)
    WatchAuras(btn)
    tiles[#tiles + 1] = btn
    return btn
end

-- Points a tile at another unit (previews). Out of combat only.
function ns.SetTileUnit(btn, unit)
    btn.unit = unit
    btn:SetAttribute("unit", unit)
    btn.dispel:SetUnit(unit)
    WatchAuras(btn)
end

-- Stops a tile for good (its part was turned off).
function ns.StopTile(btn)
    btn.off = true
    btn.auraEvents:UnregisterAllEvents()
    btn.dispel:SetEnabled(false)
end

-- Events ------------------------------------------------------------------------

local UNIT_UPDATES = {
    UNIT_HEALTH = UpdateHealth,
    UNIT_MAXHEALTH = UpdateHealth,
    UNIT_HEAL_PREDICTION = UpdateHealth,
    UNIT_CONNECTION = UpdateHealth,
    UNIT_FLAGS = UpdateHealth,
    PLAYER_FLAGS_CHANGED = UpdateHealth, -- AFK
    UNIT_NAME_UPDATE = UpdateName,
    UNIT_POWER_FREQUENT = UpdateMana,
    UNIT_MAXPOWER = UpdateMana,
    UNIT_IN_RANGE_UPDATE = UpdateRange,
}

-- `fn` on every tile whose part is on.
local function EachTile(fn)
    for _, btn in ipairs(tiles) do
        if not btn.off then fn(btn) end
    end
end

local function UpdateIcons()
    for _, btn in ipairs(tiles) do
        if not btn.off and btn:IsVisible() then UpdateIcon(btn) end
    end
end

local function StartReadyCheck()
    readyCheckOver = false
    readyCheckRound = readyCheckRound + 1
    UpdateIcons()
end

-- Answers stay a while; anyone who never answered counts as not ready.
local function EndReadyCheck()
    readyCheckOver = true
    readyCheckRound = readyCheckRound + 1
    local round = readyCheckRound
    EachTile(function(btn)
        if btn.readyStatus == "waiting" then btn.readyStatus = "notready" end
    end)
    UpdateIcons()
    C_Timer.After(READY_CHECK_LINGER, function()
        if round ~= readyCheckRound then return end -- a new check began
        readyCheckOver = false
        EachTile(function(btn) btn.readyStatus = nil end)
        UpdateIcons()
    end)
end

-- Events about the whole group, not one member. Icon events come for any
-- unit token (raid3 or player for you), so every tile rereads its icon.
local GROUP_UPDATES = {
    PLAYER_ENTERING_WORLD = function()
        LearnHotNames()
        EachTile(UpdateAll)
    end,
    GROUP_ROSTER_UPDATE = function() EachTile(UpdateAll) end,
    PLAYER_ROLES_ASSIGNED = function() EachTile(UpdateAll) end,
    PLAYER_TARGET_CHANGED = function() EachTile(UpdateSelected) end,
    PLAYER_FOCUS_CHANGED = function() EachTile(UpdateSelected) end,
    READY_CHECK = StartReadyCheck,
    READY_CHECK_CONFIRM = UpdateIcons,
    READY_CHECK_FINISHED = EndReadyCheck,
    INCOMING_RESURRECT_CHANGED = UpdateIcons,
    INCOMING_SUMMON_CHANGED = UpdateIcons,
}

local events = CreateFrame("Frame")
for event in pairs(GROUP_UPDATES) do pcall(events.RegisterEvent, events, event) end
for event in pairs(UNIT_UPDATES) do pcall(events.RegisterEvent, events, event) end

events:SetScript("OnEvent", function(_, event, unit)
    local group = GROUP_UPDATES[event]
    if group then
        group()
        return
    end
    local update = UNIT_UPDATES[event]
    -- Some payloads are secret (range always): the unit can't
    -- be compared, so every shown tile updates.
    local anyUnit = IsSecret(unit)
    for _, btn in ipairs(tiles) do
        if not btn.off and btn:IsVisible() and (anyUnit or btn.unit == unit) then
            update(btn)
        end
    end
end)

-- UNIT_IN_RANGE_UPDATE only fires when the game sees range change, and it
-- misses some: a member read as out of range while still loading in (after a
-- loading screen, a join, or zoning) stayed dim until /reload. So range is
-- also re-read twice a second while you're in a group.
C_Timer.NewTicker(0.5, function()
    if not IsInGroup() then return end
    for _, btn in ipairs(tiles) do
        if not btn.off and btn:IsVisible() then UpdateRange(btn) end
    end
end)

function ns.OnHealSelectionChanged()
    for _, btn in ipairs(tiles) do
        if not btn.off then UpdateSelected(btn) end
    end
end

-- /hoheui hots says, per HoT, whether the game keeps its auras readable in
-- combat. A secret one only shows in combat if it was already up before.
local function ProbeHots()
    local getSecrecy = C_Secrets and C_Secrets.GetSpellAuraSecrecy
    local levels = {}
    for key, value in pairs(Enum.SecrecyLevel or {}) do levels[value] = key end
    local timer = TIMER_REMAINING and C_UnitAuras.GetAuraDuration and "drain timer available" or "no drain timer"
    print("HoheUI: HoT check (" .. timer .. ")")
    for _, hot in ipairs(HOTS) do
        local name = C_Spell.GetSpellName(hot.spell) or ("spell " .. hot.spell)
        local level = "unknown"
        if getSecrecy then
            local ok, value = pcall(getSecrecy, hot.spell)
            if ok then level = levels[value] or tostring(value) end
        end
        print("  " .. name .. ": " .. level)
    end
end

ns.AddCommand("hots", "check whether HoTs stay readable in combat", ProbeHots)

-- /hoheui states says which of the APIs behind tile states this client has.
-- A missing one just never shows its state or icon.
local function ProbeStates()
    local apis = {
        { "UnitIsGhost", UnitIsGhost, "Ghost" },
        { "UnitIsAFK", UnitIsAFK, "AFK" },
        { "UnitHasIncomingResurrection", UnitHasIncomingResurrection, "res icon" },
        { "C_IncomingSummon", C_IncomingSummon and C_IncomingSummon.IncomingSummonStatus, "summon icon" },
        { "GetReadyCheckStatus", GetReadyCheckStatus, "ready check icon" },
        { "UnitHealthPercent + curves", UnitHealthPercent and C_CurveUtil, "health text in combat" },
    }
    print("HoheUI: tile state check")
    for _, api in ipairs(apis) do
        print("  " .. api[1] .. ": " .. (api[2] and "yes" or "MISSING") .. " (" .. api[3] .. ")")
    end
    local dead = UnitIsDead("player")
    print("  your dead flag is " .. (IsSecret(dead) and "secret" or "readable") .. " right now")
end

ns.AddCommand("states", "check which tile states this client supports", ProbeStates)
