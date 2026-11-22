-- Loot rolls: Need / Greed / Pass in one panel made for the controller.
--
-- In a fight it folds into a tray on the right edge of the screen: a row per
-- item with its icon (hover for the tooltip, shift-click to link) and small
-- Need / Greed / Disenchant / Pass buttons for the mouse. A click rolls at
-- once; for half a second after the rows change clicks are ignored, so a
-- double-click can't land on the item that slid into place. The tray never
-- takes a pad button and turns amber when a roll is about to run out.
-- Select (the "Loot rolls" key) opens the full panel and hands it the pad, in
-- a fight too; Select again gives the pad back.
-- Out of combat it opens by itself into a card per item, with the game's
-- tooltip (and the compare against what you wear) for the picked one, and
-- the pad chooses:
--     hold Y  Need     hold X  Greed     hold B  Pass     hold D-pad right  Disenchant
--     D-pad up / down  pick the item
-- (Y is Triangle on a PlayStation pad.) A stays yours, so you can still jump.
-- A tap does nothing: a choice is a hold, and presses in the first 1.5s
-- after a fight (or after the panel opens) are ignored, so a button spammed
-- as the last mob dies can't roll. The hold also answers the game's "Bind on
-- pickup" question for that roll.
--
-- Blizzard's roll windows (the mouse one and the gamepad one) are hidden, so
-- the gamepad one can't take the controller in a fight. Controller Forever's
-- own roll keys are told to stand down (ControllerForever.LootRoll.isOpen):
-- with no Blizzard window up they would roll on the first announced roll.
-- That depends on CF internals, so recheck it after CF updates.
--
-- Select can't focus this panel the way it focuses the game's windows: only
-- frames registered with the game's focus manager get that, and registering
-- one from an addon is blocked as Blizzard-only (PulseHaptics hit it on this
-- client). So HoheUI takes Select itself for fights, and out of combat while
-- rolls are up.
local _, ns = ...

local C = ns.COLORS

local WIDTH = 380
local PAD = 10
local HEADER = 30
local CARD_HEIGHT = 52
local CARD_GAP = 6
local BUTTON_HEIGHT = 30
local MAX_CARDS = 6
local ARM_DELAY = 1.5 -- seconds a fresh panel ignores the pad
local URGENT = 15 -- seconds left that turn the tray amber

-- The tray, in canvas units: its top right corner sits TRAY_RIGHT in from the
-- screen's right edge and TRAY_TOP above the middle, and it grows down.
local TRAY_WIDTH = 300
local TRAY_HEADER = 42
local TRAY_RIGHT = 24
local TRAY_TOP = 160
local ROW_HEIGHT = 34
local ROW_GAP = 4
local MINI = 24 -- a roll button's size
local MINI_GAP = 3
local TRAY_ARM = 0.5 -- seconds clicks are ignored after the rows change

local db = ns.AddOptions("loot", {
    { key = "enabled", kind = "toggle", label = "Loot rolls", default = true, reload = true,
      hint = "HoheUI's roll panel in place of Blizzard's roll windows." },
    { key = "hold", kind = "range", label = "Hold to choose", default = 0.6, min = 0.3, max = 1.5, step = 0.1,
      hint = "Seconds a button is held before it rolls." },
    { key = "scale", kind = "range", label = "Size", default = 1, min = 0.5, max = 2, step = 0.05, percent = true },
})

ns.AddOptions("binds", {
    { key = "loot", kind = "bind", label = "Loot rolls", default = "PADBACK", click = "HoheUILootToggle",
      needs = "loot", manual = true,
      hint = "Opens or hides the roll panel, in a fight too. HoheUI holds it in fights and while rolls are up." },
})

-- RollOnLoot's roll types, the pad button that holds each one (a face
-- button's glyph, else `pad` as text), and the game's icon for the tray.
local KINDS = {
    need = { roll = 1, face = "Y", key = "PAD4", label = NEED or "Need", color = C.friendly,
             icon = "Interface\\Buttons\\UI-GroupLoot-Dice-Up" },
    greed = { roll = 2, face = "X", key = "PAD3", label = GREED or "Greed", color = C.neutral,
              icon = "Interface\\Buttons\\UI-GroupLoot-Coin-Up" },
    disenchant = { roll = 3, pad = "Right", key = "PADDRIGHT", label = ROLL_DISENCHANT or "Disenchant", color = C.curse,
                   icon = "Interface\\Buttons\\UI-GroupLoot-DE-Up" },
    pass = { roll = 0, face = "B", key = "PAD2", label = PASS or "Pass", color = C.muted,
             icon = "Interface\\Buttons\\UI-GroupLoot-Pass-Up" },
}
local ORDER = { "need", "greed", "disenchant", "pass" }
local TRANSMOG = 4

-- The inventory slots an item would go in, for the item level compare.
local SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
    INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 }, INVTYPE_WEAPON = { 16, 17 },
    INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 },
    INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}

-- State --------------------------------------------------------------------------

local rolls = {} -- { id, duration, expires (previews only), preview = info }, oldest first
local selected -- the picked roll's id
local open = false -- the panel is up (else the tray)
local armedAt = 0
local holding -- the kind whose button is held
local chosen = {} -- roll id -> the roll type we sent, to answer its confirmation
local tipFor, tipHeight -- the roll the tooltip shows, and the panel height it was placed for

local function Find(id)
    for i, roll in ipairs(rolls) do
        if roll.id == id then return i, roll end
    end
end

local function Selected()
    local _, roll = Find(selected)
    if not roll then
        roll = rolls[1]
        selected = roll and roll.id
    end
    return roll
end

local function TimeLeft(roll)
    if roll.preview then return math.max(0, roll.expires - GetTime()) end
    return (GetLootRollTimeLeft(roll.id) or 0) / 1000
end

local function Info(roll)
    if roll.preview then return roll.preview end
    local texture, name, count, quality, bindOnPickUp, canNeed, canGreed, canDisenchant, reasonNeed, _, _, _,
        canTransmog = GetLootRollItemInfo(roll.id)
    return {
        texture = texture, name = name, count = count, quality = quality, bindOnPickUp = bindOnPickUp,
        canNeed = canNeed, canGreed = canGreed, canDisenchant = canDisenchant, reasonNeed = reasonNeed,
        canTransmog = canTransmog, link = GetLootRollItemLink(roll.id),
    }
end

local function Usable(kind, info)
    if kind == "need" then return info.canNeed end
    if kind == "greed" then return info.canGreed or info.canTransmog end
    if kind == "disenchant" then return info.canDisenchant end
    return true
end

local function AddRoll(id, durationMs)
    if Find(id) then return end
    local duration = (durationMs or GetLootRollTimeLeft(id) or 0) / 1000
    if duration <= 0 then duration = 60 end
    rolls[#rolls + 1] = { id = id, duration = duration }
end

local function RemoveRoll(id)
    local i = Find(id)
    if not i then return end
    table.remove(rolls, i)
    if selected == id then
        local nextRoll = rolls[i] or rolls[i - 1]
        selected = nextRoll and nextRoll.id
    end
end

local function QualityColor(quality)
    if quality and C_Item.GetItemQualityColor then
        local r, g, b = C_Item.GetItemQualityColor(quality)
        if r then return r, g, b end
    end
    return C.text[1], C.text[2], C.text[3]
end

-- A pad button's glyph, drawn by Controller Forever when it's there.
local function Face(face)
    local bar = ControllerForever and ControllerForever.RuleBar
    if bar and bar.faceMarkup then return bar.faceMarkup(face, 14) end
    return face
end

-- Frames ---------------------------------------------------------------------------

local anchor = CreateFrame("Frame", "HoheUILoot", ns.root)
anchor:SetSize(WIDTH, 1)
anchor:SetFrameStrata("MEDIUM")
anchor:Hide()

-- The tray ----------------------------------------------------------------------

local tray = CreateFrame("Frame", "HoheUILootTray", ns.root)
tray:SetWidth(TRAY_WIDTH)
tray:SetFrameStrata("MEDIUM")
tray:EnableMouse(true) -- a click between its buttons doesn't fall through to the world
tray:Hide()
ns.CreatePanel(tray)

tray.glow = tray:CreateTexture(nil, "BACKGROUND", nil, -6)
tray.glow:SetAllPoints()
tray.glow:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
tray.glow:SetAlpha(0)
tray.pulse = tray.glow:CreateAnimationGroup()
tray.pulse:SetLooping("BOUNCE")
local fade = tray.pulse:CreateAnimation("Alpha")
fade:SetFromAlpha(0.08)
fade:SetToAlpha(0.4)
fade:SetDuration(0.6)
tray.pulse:SetScript("OnStop", function() tray.glow:SetAlpha(0) end)

tray.title = ns.CreateText(tray, 13, ns.FONT_TEXT, C.text)
tray.title:SetPoint("TOPLEFT", PAD, -8)
tray.title:SetPoint("RIGHT", tray, "RIGHT", -PAD, 0)
tray.title:SetJustifyH("LEFT")
tray.title:SetWordWrap(false)
tray.hint = ns.CreateText(tray, 11, ns.FONT_TEXT, C.muted)
tray.hint:SetPoint("TOPLEFT", tray.title, "BOTTOMLEFT", 0, -3)
tray.hint:SetPoint("RIGHT", tray, "RIGHT", -PAD, 0)
tray.hint:SetJustifyH("LEFT")
tray.hint:SetWordWrap(false)

-- The panel above the player frame, growing up; the tray on the right edge.
local function Place()
    anchor:SetScale(db.scale)
    anchor:ClearAllPoints()
    anchor:SetPoint("BOTTOM", ns.root, "CENTER", 0, (ns.PLAYER_TOP + 40) / db.scale)
    tray:SetScale(db.scale)
    tray:ClearAllPoints()
    tray:SetPoint("TOPRIGHT", ns.root, "RIGHT", -TRAY_RIGHT / db.scale, TRAY_TOP / db.scale)
end

-- The panel ---------------------------------------------------------------------

local panel = CreateFrame("Frame", nil, anchor)
panel:SetPoint("BOTTOM")
panel:SetWidth(WIDTH)
panel:EnableMouse(true)
ns.CreatePanel(panel)

panel.title = ns.CreateText(panel, 14, ns.FONT_TEXT, C.text)
panel.title:SetPoint("TOPLEFT", PAD, -9)
panel.title:SetText(LOOT or "Loot")
panel.status = ns.CreateText(panel, 11, ns.FONT_TEXT, C.muted)
panel.status:SetPoint("TOPRIGHT", -PAD, -11)

local cards = {}
local Refresh

local function CreateCard(i)
    local card = CreateFrame("Button", nil, panel)
    card:SetHeight(CARD_HEIGHT)
    card:SetPoint("TOPLEFT", PAD, -(HEADER + (i - 1) * (CARD_HEIGHT + CARD_GAP)))
    card:SetPoint("TOPRIGHT", -PAD, -(HEADER + (i - 1) * (CARD_HEIGHT + CARD_GAP)))
    card:RegisterForClicks("LeftButtonUp")
    card:SetScript("OnClick", function(self)
        if holding then return end
        selected = self.rollID
        Refresh()
    end)

    card.bg = card:CreateTexture(nil, "BACKGROUND")
    card.bg:SetAllPoints()
    card.stripe = card:CreateTexture(nil, "ARTWORK")
    card.stripe:SetPoint("TOPLEFT")
    card.stripe:SetPoint("BOTTOMLEFT")
    card.stripe:SetWidth(3)
    card.stripe:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)

    card.border = card:CreateTexture(nil, "ARTWORK", nil, 0)
    card.border:SetSize(44, 44)
    card.border:SetPoint("LEFT", card, "LEFT", 8, 0)
    card.icon = card:CreateTexture(nil, "ARTWORK", nil, 1)
    card.icon:SetSize(40, 40)
    card.icon:SetPoint("CENTER", card.border, "CENTER")
    card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    card.count = ns.CreateText(card, 12, ns.FONT_NUMBER, C.text)
    card.count:SetPoint("BOTTOMRIGHT", card.icon, "BOTTOMRIGHT", -1, 2)

    card.time = ns.CreateText(card, 12, ns.FONT_NUMBER, C.muted)
    card.time:SetPoint("TOPRIGHT", -8, -6)

    card.name = ns.CreateText(card, 14)
    card.name:SetPoint("TOPLEFT", card.border, "TOPRIGHT", 10, 1)
    card.name:SetPoint("RIGHT", card, "RIGHT", -44, 0)
    card.name:SetJustifyH("LEFT")
    card.name:SetWordWrap(false)
    card.info = ns.CreateText(card, 12, ns.FONT_TEXT, C.muted)
    card.info:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -3)
    card.info:SetPoint("RIGHT", card, "RIGHT", -8, 0)
    card.info:SetJustifyH("LEFT")
    card.info:SetWordWrap(false)
    card.note = ns.CreateText(card, 12, ns.FONT_TEXT, C.muted)
    card.note:SetPoint("TOPLEFT", card.info, "BOTTOMLEFT", 0, -2)
    card.note:SetPoint("RIGHT", card, "RIGHT", -8, 0)
    card.note:SetJustifyH("LEFT")
    card.note:SetWordWrap(false)

    card.timer = ns.CreateBar(card, 2, C.muted)
    card.timer:SetPoint("BOTTOMLEFT", card.border, "BOTTOMRIGHT", 10, -3)
    card.timer:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -8, 3)
    cards[i] = card
    return card
end

-- The hold buttons. Named, so pad presses can click them: a press is the
-- click going down, a release the click coming up.
local buttons = {}
local StartHold, StopHold, FinishHold

for _, kind in ipairs(ORDER) do
    local spec = KINDS[kind]
    local b = CreateFrame("Button", "HoheUILoot" .. kind:sub(1, 1):upper() .. kind:sub(2), panel)
    b:SetHeight(BUTTON_HEIGHT)
    b:RegisterForClicks("AnyDown", "AnyUp")
    b:SetScript("OnClick", function(_, _, down)
        if down then StartHold(kind) else StopHold(kind) end
    end)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(ns.TRACK[1], ns.TRACK[2], ns.TRACK[3], ns.TRACK[4])
    b.fill = b:CreateTexture(nil, "ARTWORK")
    b.fill:SetAllPoints()
    b.fill:SetColorTexture(spec.color[1], spec.color[2], spec.color[3], 0.55)
    b.fill:Hide()
    b.anim = b.fill:CreateAnimationGroup()
    b.grow = b.anim:CreateAnimation("Scale")
    b.grow:SetScaleFrom(0.01, 1)
    b.grow:SetScaleTo(1, 1)
    b.grow:SetOrigin("LEFT", 0, 0)
    b.anim:SetScript("OnFinished", function() FinishHold(kind) end)
    b.label = ns.CreateText(b, 13)
    b.label:SetPoint("CENTER")
    buttons[kind] = b
end

local function Armed()
    return GetTime() >= armedAt
end

-- Presses are ignored for a moment, and a held button starts over.
local function Arm()
    StopHold()
    armedAt = GetTime() + ARM_DELAY
    C_Timer.After(ARM_DELAY + 0.05, function() Refresh() end)
end

function StartHold(kind)
    if not open or not Armed() then return end
    local roll = Selected()
    if not roll or not Usable(kind, Info(roll)) then return end
    StopHold()
    holding = kind
    local b = buttons[kind]
    b.fill:Show()
    b.anim:Play()
end

-- Lets go of the held button (only that one, when a kind is given).
function StopHold(kind)
    if not holding or (kind and kind ~= holding) then return end
    local b = buttons[holding]
    holding = nil
    b.anim:Stop()
    b.fill:Hide()
end

-- Sends the roll (a preview only prints it) and drops it from the list.
local function Roll(roll, kind)
    local info = Info(roll)
    if not Usable(kind, info) then return end
    local spec = KINDS[kind]
    local rollType = spec.roll
    if kind == "greed" and not info.canGreed then rollType = TRANSMOG end
    local what = info.link or info.name or "?"
    if roll.preview then
        print("HoheUI: " .. spec.label .. " on " .. what .. " (preview, nothing rolled)")
    else
        chosen[roll.id] = rollType
        RollOnLoot(roll.id, rollType)
        print("HoheUI: " .. spec.label .. " on " .. what)
    end
    RemoveRoll(roll.id)
    Refresh()
end

function FinishHold(kind)
    if holding ~= kind then return end
    StopHold()
    local roll = Selected()
    if roll then Roll(roll, kind) end
end

-- Cards ----------------------------------------------------------------------------

-- "Chest · Cloth · ilvl 60 · BoP", and the item's level and slot for the compare.
local function Details(info)
    local parts = {}
    local itemType, subType, itemLevel, equipLoc, bindType
    if info.link then
        _, _, _, itemLevel, _, itemType, subType, _, equipLoc, _, _, _, _, bindType = C_Item.GetItemInfo(info.link)
        if not itemType then
            C_Item.RequestLoadItemDataByID(info.link)
            return "Loading", nil, nil
        end
    end
    local slot = equipLoc and equipLoc ~= "" and _G[equipLoc]
    if slot then parts[#parts + 1] = slot end
    if subType and subType ~= "" and subType ~= slot then
        parts[#parts + 1] = subType
    elseif itemType then
        parts[#parts + 1] = itemType
    end
    if slot and itemLevel then parts[#parts + 1] = "ilvl " .. itemLevel end
    if info.bindOnPickUp or bindType == 1 then
        parts[#parts + 1] = "BoP"
    elseif bindType == 2 then
        parts[#parts + 1] = "BoE"
    elseif bindType == 3 then
        parts[#parts + 1] = "BoU"
    end
    return table.concat(parts, " · "), slot and itemLevel, equipLoc
end

-- The lowest item level worn in the slots it would go in (0 for an empty
-- one), or nil while a worn item isn't loaded.
local function WornLevel(equipLoc)
    local lowest
    for _, slot in ipairs(SLOTS[equipLoc] or {}) do
        local link = GetInventoryItemLink("player", slot)
        local level = 0
        if link then level = select(4, C_Item.GetItemInfo(link)) end
        if level and (not lowest or level < lowest) then lowest = level end
    end
    return lowest
end

-- Why it can't be needed, else how it compares with what you wear.
local function Note(info, itemLevel, equipLoc)
    if not info.canNeed and info.reasonNeed and info.reasonNeed > 0 then
        local reason = _G["LOOT_ROLL_INELIGIBLE_REASON" .. info.reasonNeed]
        if reason then return reason, C.muted end
    end
    local worn = itemLevel and SLOTS[equipLoc] and WornLevel(equipLoc)
    if not worn or ns.IsSecret(worn) or ns.IsSecret(itemLevel) then return "", C.muted end
    if worn == 0 then return "Upgrade: that slot is empty", C.friendly end
    local diff = itemLevel - worn
    if diff > 0 then return "Upgrade: +" .. diff .. " item level over yours", C.friendly end
    if diff == 0 then return "Same item level as yours", C.muted end
    return -diff .. " item level below yours", C.muted
end

local function UpdateCard(card, roll)
    local info = Info(roll)
    local r, g, b = QualityColor(info.quality)
    card.rollID = roll.id
    card.icon:SetTexture(info.texture)
    card.border:SetColorTexture(r, g, b, 1)
    card.count:SetText(info.count and info.count > 1 and info.count or "")
    card.name:SetText(info.name or "")
    card.name:SetTextColor(r, g, b)
    local details, itemLevel, equipLoc = Details(info)
    card.info:SetText(details)
    local note, color = Note(info, itemLevel, equipLoc)
    card.note:SetText(note)
    card.note:SetTextColor(color[1], color[2], color[3])

    local left = TimeLeft(roll)
    card.time:SetFormattedText("%ds", math.ceil(left))
    local timeColor = left <= URGENT and C.accent or C.muted
    card.time:SetTextColor(timeColor[1], timeColor[2], timeColor[3])
    card.timer:SetMinMaxValues(0, roll.duration)
    card.timer:SetValue(left)

    local picked = roll.id == selected
    card.stripe:SetShown(picked)
    local shade = picked and 0.18 or ns.TRACK[1]
    card.bg:SetColorTexture(shade, shade + 0.01, shade + 0.03, ns.TRACK[4])
    card:Show()
end

-- The tooltip ----------------------------------------------------------------------
-- Beside the panel, with the compare against what you wear. Set again only when
-- the pick changes, so it doesn't flicker or take the tooltip back each tick.

local function HideTooltip()
    if tipFor and GameTooltip:IsOwned(panel) then GameTooltip:Hide() end
    tipFor = nil
end

local function ShowTooltip(roll)
    tipFor, tipHeight = roll.id, panel:GetHeight()
    -- Right of the panel, bottoms level. Anchored "right" rather than placed
    -- by hand, because the game puts the compare on the side the anchor
    -- names; with no anchor it took the roomier side, back over the panel.
    local y = -tipHeight * panel:GetEffectiveScale() / GameTooltip:GetEffectiveScale()
    GameTooltip:SetOwner(panel, "ANCHOR_RIGHT", 8, y)
    if roll.preview then
        GameTooltip:SetHyperlink(roll.preview.link)
    else
        GameTooltip:SetLootRollItem(roll.id)
    end
    GameTooltip:Show()
    if GameTooltip_ShowCompareItem then GameTooltip_ShowCompareItem(GameTooltip) end
end

-- Tray rows ------------------------------------------------------------------------
-- A row per roll for the mouse: hover the item for its tooltip (with the
-- compare), shift-click it to link it, click a small button to roll.

local trayRows = {}
local trayArmedAt, traySig = 0, nil

local function TrayArmed()
    return GetTime() >= trayArmedAt
end

-- The tooltip goes left of the tray, bottoms level with the row.
local function ShowRowTip(row)
    local _, roll = Find(row.rollID)
    if not roll then return end
    local s = row:GetEffectiveScale() / GameTooltip:GetEffectiveScale()
    GameTooltip:SetOwner(row, "ANCHOR_LEFT", -(PAD + 6) * s, -row:GetHeight() * s)
    if roll.preview then
        GameTooltip:SetHyperlink(roll.preview.link)
    else
        GameTooltip:SetLootRollItem(roll.id)
    end
    GameTooltip:Show()
    if GameTooltip_ShowCompareItem then GameTooltip_ShowCompareItem(GameTooltip) end
end

local function ShowKindTip(b)
    local _, roll = Find(b:GetParent().rollID)
    if not roll then return end
    local info = Info(roll)
    local spec = KINDS[b.kind]
    local label = spec.label
    if b.kind == "greed" and not info.canGreed and info.canTransmog then label = "Transmog" end
    GameTooltip:SetOwner(b, "ANCHOR_TOP")
    GameTooltip:SetText(label, spec.color[1], spec.color[2], spec.color[3])
    if not Usable(b.kind, info) then
        local reason = b.kind == "need" and info.reasonNeed and info.reasonNeed > 0
            and _G["LOOT_ROLL_INELIGIBLE_REASON" .. info.reasonNeed]
        GameTooltip:AddLine(reason or "Not available for this item", C.muted[1], C.muted[2], C.muted[3], true)
    end
    GameTooltip:Show()
end

local function HideTipOf(frame)
    if GameTooltip:IsOwned(frame) then GameTooltip:Hide() end
end

local function HideRowTips(row)
    HideTipOf(row)
    for _, b in pairs(row.buttons) do HideTipOf(b) end
end

local function CreateRow(i)
    local row = CreateFrame("Button", nil, tray)
    local y = -(TRAY_HEADER + (i - 1) * (ROW_HEIGHT + ROW_GAP))
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", PAD, y)
    row:SetPoint("TOPRIGHT", -PAD, y)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function(self)
        local _, roll = Find(self.rollID)
        local link = roll and Info(roll).link
        if link then HandleModifiedItemClick(link) end
    end)
    row:SetScript("OnEnter", ShowRowTip)
    row:SetScript("OnLeave", HideTipOf)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(ns.TRACK[1], ns.TRACK[2], ns.TRACK[3], ns.TRACK[4])
    row.border = row:CreateTexture(nil, "ARTWORK", nil, 0)
    row.border:SetSize(30, 30)
    row.border:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.icon = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.icon:SetSize(26, 26)
    row.icon:SetPoint("CENTER", row.border, "CENTER")
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.count = ns.CreateText(row, 11, ns.FONT_NUMBER, C.text)
    row.count:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", -1, 1)

    -- Need, Greed, Disenchant, Pass from left to right, each in a fixed
    -- column so Pass is always in the same place.
    row.buttons = {}
    for j, kind in ipairs(ORDER) do
        local spec = KINDS[kind]
        local b = CreateFrame("Button", nil, row)
        b.kind = kind
        b:SetSize(MINI, MINI)
        b:SetPoint("RIGHT", row, "RIGHT", -(4 + (#ORDER - j) * (MINI + MINI_GAP)), 0)
        b:RegisterForClicks("LeftButtonUp")
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.bg:SetColorTexture(spec.color[1], spec.color[2], spec.color[3], 0.2)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 2, -2)
        b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        b.icon:SetTexture(spec.icon)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.18)
        b:SetScript("OnClick", function(self)
            if not TrayArmed() then return end
            local _, roll = Find(self:GetParent().rollID)
            if roll then Roll(roll, self.kind) end
        end)
        b:SetScript("OnEnter", ShowKindTip)
        b:SetScript("OnLeave", HideTipOf)
        row.buttons[kind] = b
    end
    local first = row.buttons[ORDER[1]]

    row.name = ns.CreateText(row, 12)
    row.name:SetPoint("TOPLEFT", row.border, "TOPRIGHT", 8, 0)
    row.name:SetPoint("RIGHT", first, "LEFT", -6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.time = ns.CreateText(row, 11, ns.FONT_NUMBER, C.muted)
    row.time:SetPoint("BOTTOMLEFT", row.border, "BOTTOMRIGHT", 8, 0)
    row.timer = ns.CreateBar(row, 2, C.muted)
    row.timer:SetPoint("LEFT", row.time, "RIGHT", 6, 0)
    row.timer:SetPoint("RIGHT", first, "LEFT", -6, 0)
    trayRows[i] = row
    return row
end

local function UpdateRow(row, roll)
    local info = Info(roll)
    local moved = row.rollID ~= roll.id
    row.rollID = roll.id
    local r, g, b = QualityColor(info.quality)
    row.border:SetColorTexture(r, g, b, 1)
    row.icon:SetTexture(info.texture)
    row.count:SetText(info.count and info.count > 1 and info.count or "")
    row.name:SetText(info.name or "")
    row.name:SetTextColor(r, g, b)

    local left = TimeLeft(roll)
    local color = left <= URGENT and C.accent or C.muted
    row.time:SetFormattedText("%ds", math.ceil(left))
    row.time:SetTextColor(color[1], color[2], color[3])
    row.timer:SetStatusBarColor(color[1], color[2], color[3])
    row.timer:SetMinMaxValues(0, roll.duration)
    row.timer:SetValue(left)

    local armed = TrayArmed()
    for kind, button in pairs(row.buttons) do
        local usable = Usable(kind, info)
        button.icon:SetDesaturated(not usable)
        button:SetAlpha((usable and armed) and 1 or 0.3)
        button:SetShown(kind ~= "disenchant" or info.canDisenchant)
    end
    row:Show()

    -- A row now showing another item: its tooltip follows.
    if moved then
        if GameTooltip:IsOwned(row) then ShowRowTip(row) end
        for _, button in pairs(row.buttons) do
            if GameTooltip:IsOwned(button) then
                if button:IsShown() then ShowKindTip(button) else GameTooltip:Hide() end
            end
        end
    end
end

local function HideTray()
    for _, row in ipairs(trayRows) do HideRowTips(row) end
    tray.pulse:Stop()
    tray:Hide()
    traySig = nil
end

-- Drawing ------------------------------------------------------------------------

local function ShowPanel()
    HideTray()
    anchor:Show()
    panel:Show()
    local roll = Selected()
    local shown = math.min(#rolls, MAX_CARDS)
    for i = 1, shown do UpdateCard(cards[i] or CreateCard(i), rolls[i]) end
    for i = shown + 1, #cards do cards[i]:Hide() end

    local extra = #rolls - shown
    local status = Armed() and "Hold to choose" or "Ready in a moment"
    if extra > 0 then status = status .. " · " .. extra .. " more after these" end
    local key = ns.Settings("binds").loot
    if key then status = status .. " · " .. ns.KeyText(key) .. " closes" end
    panel.status:SetText(status)

    -- Disenchant only for items that offer it; the rest share the row.
    local info = Info(roll)
    local visible = {}
    for _, kind in ipairs(ORDER) do
        if kind ~= "disenchant" or info.canDisenchant then
            visible[#visible + 1] = kind
        else
            if holding == kind then StopHold() end
            buttons[kind]:Hide()
        end
    end
    local gap = 6
    local width = (WIDTH - 2 * PAD - gap * (#visible - 1)) / #visible
    for i, kind in ipairs(visible) do
        local b = buttons[kind]
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PAD + (i - 1) * (width + gap), PAD)
        b:SetWidth(width)
        local spec = KINDS[kind]
        b.label:SetText((spec.face and Face(spec.face) or spec.pad) .. "  " .. spec.label)
        b:SetAlpha((Armed() and Usable(kind, info)) and 1 or 0.35)
        b:Show()
    end

    panel:SetHeight(HEADER + shown * (CARD_HEIGHT + CARD_GAP) + BUTTON_HEIGHT + PAD + 4)
    if tipFor ~= roll.id or tipHeight ~= panel:GetHeight() then ShowTooltip(roll) end
end

-- Hides the panel side: the panel, its tooltip and any hold.
local function HidePanel()
    StopHold()
    HideTooltip()
    anchor:Hide()
end

local function ShowTray()
    HidePanel()
    tray:Show()
    local shown = math.min(#rolls, MAX_CARDS)

    -- New rows, or rows that slid up after a roll: ignore clicks for a moment.
    local ids = {}
    for i = 1, shown do ids[i] = rolls[i].id end
    local sig = table.concat(ids, ",")
    if sig ~= traySig then
        traySig = sig
        trayArmedAt = GetTime() + TRAY_ARM
        C_Timer.After(TRAY_ARM + 0.05, function() Refresh() end)
    end

    for i = 1, shown do UpdateRow(trayRows[i] or CreateRow(i), rolls[i]) end
    for i = shown + 1, #trayRows do
        HideRowTips(trayRows[i])
        trayRows[i]:Hide()
    end

    local soonest
    for _, roll in ipairs(rolls) do
        local left = TimeLeft(roll)
        if not soonest or left < soonest then soonest = left end
    end
    local urgent = soonest <= URGENT
    local count = #rolls
    if urgent then
        tray.title:SetFormattedText("Rolls ending  %ds", math.ceil(soonest))
    else
        tray.title:SetFormattedText("%d %s  %ds", count, count == 1 and "roll" or "rolls", math.ceil(soonest))
    end
    if count > shown then tray.title:SetText(tray.title:GetText() .. "  · " .. (count - shown) .. " more after these") end
    local color = urgent and C.accent or C.text
    tray.title:SetTextColor(color[1], color[2], color[3])
    if urgent and not tray.pulse:IsPlaying() then
        tray.pulse:Play()
    elseif not urgent and tray.pulse:IsPlaying() then
        tray.pulse:Stop()
    end

    local key = ns.Settings("binds").loot
    tray.hint:SetText("Click to roll" .. (key and ("  · " .. ns.KeyText(key) .. " for the pad") or ""))
    tray:SetHeight(TRAY_HEADER + shown * (ROW_HEIGHT + ROW_GAP) - ROW_GAP + PAD)
end

-- The pad's keys while the panel is up out of combat: above Controller
-- Forever's helpers for game windows, and let go when a fight starts (its
-- binds put them back after). Without CF they're override bindings.
local KEYS = {
    PAD4 = "HoheUILootNeed", PAD3 = "HoheUILootGreed", PADDRIGHT = "HoheUILootDisenchant", PAD2 = "HoheUILootPass",
    PADDUP = "HoheUILootUp", PADDDOWN = "HoheUILootDown",
}
local overrideOwner = CreateFrame("Frame")
local claim
local bound = false

local function Bind(want)
    if InCombatLockdown() or want == bound then return end
    bound = want
    local binds = ControllerForever and ControllerForever.Binds
    if binds and binds.claimant then
        claim = claim or binds:claimant("HoheUILoot", binds.PRIORITY.gamewindow + 1, { outOfFight = true })
        if want then
            local map = {}
            for key, button in pairs(KEYS) do map[key] = "CLICK " .. button .. ":LeftButton" end
            claim.replace(map)
        else
            claim.clear()
        end
        claim.commit()
    else
        ClearOverrideBindings(overrideOwner)
        if want then
            for key, button in pairs(KEYS) do SetOverrideBindingClick(overrideOwner, true, key, button, "LeftButton") end
        end
    end
end

-- The "Loot rolls" key (Select) clicks this. In a fight only secure code may
-- change keys, so this button's own snippet hands the pad to the panel and
-- takes it back. It can't see whether a roll is up (the panel isn't a
-- protected frame), so a press in a fight always takes the pad; the tray then
-- says the next press gives it back. The "fight" attribute is set just
-- before the lock and cleared after it.
local toggle = CreateFrame("Button", "HoheUILootToggle", UIParent, "SecureHandlerClickTemplate")
toggle:RegisterForClicks("AnyDown")
local take = {}
for key, button in pairs(KEYS) do
    take[#take + 1] = string.format("self:SetBindingClick(true, %q, %q)", key, button)
end
toggle:SetAttribute("_onclick", [[
    if self:GetAttribute("fight") then
        if self:GetAttribute("held") then
            self:SetAttribute("held", nil)
            self:ClearBindings()
        else
            self:SetAttribute("held", true)
            ]] .. table.concat(take, "\n            ") .. [[

        end
    end
    self:CallMethod("Toggled")
]])

-- Whether the toggle's snippet has the pad, in this fight.
local function Held()
    return toggle:GetAttribute("held") and true or false
end

-- Select itself: HoheUI's for every fight (it has to be claimed before one
-- starts, and a roll can come up in it) and, out of combat, while rolls are
-- up. Otherwise it's the game's, to focus its windows.
local selectOwner = CreateFrame("Frame")
local selectClaim
local selectBound = false
local fighting = false

local function UpdateSelect()
    if InCombatLockdown() then return end
    local key = db.enabled and (fighting or #rolls > 0) and ns.Settings("binds").loot or false
    if key == selectBound then return end
    selectBound = key
    local binds = ControllerForever and ControllerForever.Binds
    if binds and binds.claimant then
        -- (over the game's own sets: Select is theirs to toggle window focus)
        selectClaim = selectClaim or binds:claimant("HoheUILootSelect", binds.PRIORITY.gamewindow + 1, { overGame = true })
        if key then
            selectClaim.replace({ [key] = "CLICK HoheUILootToggle:LeftButton" })
        else
            selectClaim.clear()
        end
        selectClaim.commit()
    else
        ClearOverrideBindings(selectOwner)
        if key then SetOverrideBindingClick(selectOwner, true, key, "HoheUILootToggle", "LeftButton") end
    end
end

-- The tray with no rolls left, while the toggle still has the pad.
local function ShowReminder()
    HidePanel()
    HideTray()
    for _, row in ipairs(trayRows) do row:Hide() end
    tray:Show()
    tray.title:SetText("Your buttons are on the loot panel")
    tray.title:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
    local key = ns.Settings("binds").loot
    tray.hint:SetText((key and ns.KeyText(key) or "The loot key") .. " gives them back")
    tray:SetHeight(TRAY_HEADER)
end

local ticker

function Refresh()
    for i = #rolls, 1, -1 do
        if TimeLeft(rolls[i]) <= 0 then RemoveRoll(rolls[i].id) end
    end
    if #rolls == 0 then
        open = false
        if InCombatLockdown() and Held() then
            ShowReminder()
        else
            HidePanel()
            HideTray()
        end
        Bind(false)
        UpdateSelect()
        if ticker then
            ticker:Cancel()
            ticker = nil
        end
        return
    end
    if open then ShowPanel() else ShowTray() end
    Bind(open and not InCombatLockdown())
    UpdateSelect()
    -- The times count down, so redraw while anything is up.
    ticker = ticker or C_Timer.NewTicker(0.5, Refresh)
end

-- Opens the panel out of combat, armed after the delay.
local function OpenForReview()
    if InCombatLockdown() or #rolls == 0 then return end
    if not open then
        open = true
        Arm()
    end
end

-- Pad actions --------------------------------------------------------------------

local function Move(delta)
    if not open or #rolls == 0 then return end
    local shown = math.min(#rolls, MAX_CARDS)
    local i = math.min(Find(selected) or 1, shown)
    selected = rolls[(i - 1 + delta) % shown + 1].id
    StopHold()
    Refresh()
end

-- Out of combat the panel opens and closes; the keys follow in Refresh. In a
-- fight it follows the snippet: open while that has the pad.
function toggle:Toggled()
    if InCombatLockdown() then
        open = Held() and #rolls > 0
        if open then Arm() end
    elseif #rolls > 0 then
        open = not open
        if open then Arm() end
    end
    Refresh()
end

local function ClickButton(name, fn)
    local button = CreateFrame("Button", name, UIParent)
    button:RegisterForClicks("AnyDown")
    button:SetScript("OnClick", fn)
    return button
end
ClickButton("HoheUILootUp", function() Move(-1) end)
ClickButton("HoheUILootDown", function() Move(1) end)

-- Preview ----------------------------------------------------------------------------
-- Three of your own worn items as rolls: one urgent, one you can't need.
-- Holding a button only prints what it would have done.

local PREVIEW_SLOTS = { 5, 1, 16 }
local PREVIEW_TIMES = { 60, 40, 12 }

function ns.PreviewLoot()
    local had = false
    for i = #rolls, 1, -1 do
        if rolls[i].preview then
            RemoveRoll(rolls[i].id)
            had = true
        end
    end
    if had then
        Refresh()
        return
    end
    for i, slot in ipairs(PREVIEW_SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        local name, quality, texture
        if link then name, _, quality, _, _, _, _, _, _, texture = C_Item.GetItemInfo(link) end
        if name then
            rolls[#rolls + 1] = {
                id = -i, duration = 60, expires = GetTime() + PREVIEW_TIMES[i],
                preview = {
                    texture = texture, name = name, count = 1, quality = quality, bindOnPickUp = true,
                    canNeed = i ~= 2, canGreed = true, canDisenchant = false, reasonNeed = i == 2 and 1 or 0,
                    link = link,
                },
            }
        end
    end
    if #rolls == 0 then
        print("HoheUI: wear a chest, head or main-hand item to preview the loot panel.")
        return
    end
    OpenForReview()
    Refresh()
end

ns.AddCommand("loot", "preview the loot panel", ns.PreviewLoot)

-- Events -----------------------------------------------------------------------------

-- The game asks again before some rolls count (bind on pickup, disenchant).
-- Answered only for rolls this panel sent: the hold was the confirmation.
local function Confirm(id, rollType)
    if chosen[id] ~= rollType then return end
    ConfirmLootRoll(id, rollType)
    local function HidePopup() StaticPopup_Hide("CONFIRM_LOOT_ROLL", id) end
    HidePopup()
    C_Timer.After(0, HidePopup)
end

local function RestoreRolls()
    for _, id in ipairs(GetActiveLootRollIDs and GetActiveLootRollIDs() or {}) do
        AddRoll(id, C_Loot and C_Loot.GetLootRollDuration and C_Loot.GetLootRollDuration(id))
    end
    OpenForReview()
    Refresh()
end

local handlers = {
    START_LOOT_ROLL = function(id, rollTime)
        AddRoll(id, rollTime)
        OpenForReview()
        Refresh()
    end,
    CANCEL_LOOT_ROLL = function(id)
        chosen[id] = nil
        RemoveRoll(id)
        Refresh()
    end,
    CANCEL_ALL_LOOT_ROLLS = function()
        for i = #rolls, 1, -1 do
            if not rolls[i].preview then RemoveRoll(rolls[i].id) end
        end
        wipe(chosen)
        Refresh()
    end,
    CONFIRM_LOOT_ROLL = Confirm,
    CONFIRM_DISENCHANT_ROLL = Confirm,
    PLAYER_ENTERING_WORLD = RestoreRolls,
    -- Before the lock: the panel folds into the tray, lets go of the pad and
    -- takes Select for the fight.
    PLAYER_REGEN_DISABLED = function()
        fighting = true
        toggle:SetAttribute("fight", true)
        open = false
        Refresh()
    end,
    -- The snippet's keys go, and the panel opens armed: a button still being
    -- mashed from the fight starts nothing.
    PLAYER_REGEN_ENABLED = function()
        fighting = false
        toggle:SetAttribute("fight", nil)
        toggle:SetAttribute("held", nil)
        ClearOverrideBindings(toggle)
        if #rolls > 0 then
            open = true
            Arm()
        end
        Refresh()
    end,
    ITEM_DATA_LOAD_RESULT = function()
        if anchor:IsShown() or tray:IsShown() then Refresh() end
    end,
}

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)

-- Settings ---------------------------------------------------------------------------

ns.HideBlizzard(GamepadGroupLootRollFrame, "loot")
ns.HideBlizzard(GroupLootContainer, "loot")
for i = 1, 4 do ns.HideBlizzard(_G["GroupLootFrame" .. i], "loot") end

ns.Watch("loot", "enabled", function(on)
    if not on then return end
    for event in pairs(handlers) do pcall(events.RegisterEvent, events, event) end
end)
ns.Watch("loot", "scale", Place)
ns.Watch("binds", "loot", function() ns.AfterCombat(UpdateSelect) end)
ns.Watch("loot", "hold", function(seconds)
    for _, b in pairs(buttons) do b.grow:SetDuration(seconds) end
end)

-- Controller Forever's roll keys stand down (see the top of the file).
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
    local cf = ControllerForever and ControllerForever.LootRoll
    if not (db.enabled and cf) then return end
    cf.isOpen = function() return false end
    if cf.apply then cf.apply() end
end)
