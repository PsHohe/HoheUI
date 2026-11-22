-- Raid frames: group tiles (see Tiles.lua), smaller than the party's, in one
-- column per raid group, five rows deep. In a raid they take the party
-- column's place left of the player frame: the grid hangs from the same top
-- right corner and grows to the left as groups fill.
--
-- The grid is laid out the way Controller Forever's Healer D-pad walks a
-- raid: groups left to right in group order, empty groups skipped, members
-- top to bottom in raid order. So Up / Down move within the column the pick
-- is in and Left / Right move to the next column on screen.
--
-- Tiles are protected, so the grid is rearranged out of combat only (so is
-- Controller Forever's). A member who joins or swaps groups in a fight shows
-- at once, but in the old spot until it ends.
local _, ns = ...

local MAX_MEMBERS = 40
local ROWS = 5
local WIDTH, HEIGHT, GAP = 76, 44, 4
local STYLE = {
    width = WIDTH, height = HEIGHT,
    nameSize = 12, nameY = 4,
    healthTextSize = 11, statusSize = 11, healthTextY = -9, icon = 16,
    dispel = 12, dispelText = 9,
    hot = 8, hotInset = 2, hotGap = 1,
    mana = 4,
}

local db = ns.AddOptions("raid", {
    { key = "enabled", kind = "toggle", label = "Raid tiles", default = true, reload = true,
      hint = "Off brings back Blizzard's raid frames." },
    { key = "scale", kind = "range", label = "Size", default = 1, min = 0.5, max = 2, step = 0.05, percent = true },
    { key = "grow", kind = "toggle", label = "Grow the picked tile", default = true },
    { key = "hots", kind = "toggle", label = "Your HoTs", default = true,
      hint = "Renew, Rejuvenation and Regrowth as draining squares." },
    { key = "dispel", kind = "toggle", label = "Debuffs you can dispel", default = true },
    { key = "mana", kind = "toggle", label = "Healer mana", default = true },
    { key = "healthText", kind = "choice", label = "Health text", default = "lost",
      choices = ns.HEALTH_TEXT_CHOICES,
      hint = "Lost shows only while hurt; Percent and Remaining always show." },
    { key = "preview", kind = "button", label = "Preview", text = "Show / hide",
      hint = "A full raid of you, to see the layout without a group.", run = function() ns.ToggleRaidTest() end },
})
local player = ns.Settings("player")

local members = {}
local testing = false

-- The grid's top right corner sits where the party column's does, with its
-- top two rows above the player frame's health bar.
local grid = CreateFrame("Frame", "HoheUIRaidGrid", ns.root)
grid:SetSize(WIDTH, ROWS * HEIGHT + (ROWS - 1) * GAP)
ns.raidGrid = grid

local function PlaceGrid()
    local scale, playerScale = db.scale, player.scale
    local right = -(ns.player:GetWidth() * playerScale / 2) - 56
    local top = ns.PLAYER_TOP - 20 * playerScale + 2 * (HEIGHT + GAP) * scale
    grid:SetScale(scale)
    grid:ClearAllPoints()
    grid:SetPoint("TOPRIGHT", ns.root, "CENTER", right / scale, top / scale)
end
PlaceGrid()

-- Where each raid index goes, { col, row }, and how many columns there are.
local function Spots()
    local spots = {}
    if testing then
        for i = 1, MAX_MEMBERS do
            spots[i] = { col = math.ceil(i / ROWS), row = (i - 1) % ROWS + 1 }
        end
        return spots, MAX_MEMBERS / ROWS
    end
    local rows = {}
    for i = 1, math.min(GetNumGroupMembers(), MAX_MEMBERS) do
        local _, _, subgroup = GetRaidRosterInfo(i)
        if subgroup and not ns.IsSecret(subgroup) then
            rows[subgroup] = (rows[subgroup] or 0) + 1
            spots[i] = { col = subgroup, row = rows[subgroup] }
        end
    end
    -- Empty groups take no column.
    local columns, cols = {}, 0
    for group = 1, 8 do
        if rows[group] then
            cols = cols + 1
            columns[group] = cols
        end
    end
    for _, spot in pairs(spots) do spot.col = columns[spot.col] end
    return spots, cols
end

local function Layout()
    if not IsInRaid() and not testing then return end
    local spots, cols = Spots()
    for i, btn in ipairs(members) do
        local spot = spots[i]
        if spot then
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", grid, "TOPLEFT", (spot.col - 1) * (WIDTH + GAP), -(spot.row - 1) * (HEIGHT + GAP))
        end
    end
    grid:SetWidth(math.max(cols, 1) * (WIDTH + GAP) - GAP)
end

for i = 1, MAX_MEMBERS do
    local btn = ns.CreateTile(grid, "raid" .. i, "HoheUIRaid" .. i, STYLE, db)
    btn.index = i
    btn:SetPoint("TOPLEFT")
    RegisterUnitWatch(btn)
    members[i] = btn
end
ns.raidTiles = members

-- In a raid the party column steps aside. The game does it, so it holds in
-- combat.
local function HidePartyInRaid()
    RegisterStateDriver(ns.partyColumn, "visibility", "[group:raid] hide; show")
end

-- Events ------------------------------------------------------------------------

local handlers = {}

function handlers.GROUP_ROSTER_UPDATE()
    ns.AfterCombat(Layout)
end
handlers.PLAYER_ENTERING_WORLD = handlers.GROUP_ROSTER_UPDATE

local events = CreateFrame("Frame")
for event in pairs(handlers) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)

-- Test mode -------------------------------------------------------------------
-- /hoheui raid shows forty tiles of you, to check the layout without a raid.
-- The party column is hidden meanwhile, since the grid sits where it does.

function ns.ToggleRaidTest()
    if not db.enabled then return end
    if InCombatLockdown() then
        print("HoheUI: can't change raid frames in combat.")
        return
    end
    testing = not testing
    for _, btn in ipairs(members) do
        ns.SetTileUnit(btn, testing and "player" or btn.homeUnit)
        if testing then
            UnregisterUnitWatch(btn)
            btn:Show()
            ns.UpdateTile(btn)
        else
            RegisterUnitWatch(btn)
        end
    end
    if testing then
        UnregisterStateDriver(ns.partyColumn, "visibility")
        ns.partyColumn:Hide()
    else
        HidePartyInRaid()
    end
    Layout()
end

ns.AddCommand("raid", "preview the raid frames", ns.ToggleRaidTest)

-- Settings ---------------------------------------------------------------------

local function RefreshAll()
    for _, btn in ipairs(members) do
        if btn:IsVisible() then ns.UpdateTile(btn) end
    end
end

ns.Watch("raid", "enabled", function(on)
    if on then
        ns.AfterCombat(HidePartyInRaid)
        return
    end
    events:UnregisterAllEvents()
    for _, btn in ipairs(members) do ns.StopTile(btn) end
    ns.AfterCombat(function()
        for _, btn in ipairs(members) do
            UnregisterUnitWatch(btn)
            btn:Hide()
        end
    end)
end)
ns.Watch("raid", "scale", function() ns.AfterCombat(PlaceGrid) end)
ns.Watch("player", "scale", function() ns.AfterCombat(PlaceGrid) end)
for _, key in ipairs({ "grow", "hots", "dispel", "mana", "healthText" }) do ns.Watch("raid", key, RefreshAll) end

ns.HideBlizzard(CompactRaidFrameContainer, "raid")
