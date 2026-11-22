-- Party frames: a column of group tiles (see Tiles.lua) to the left of the
-- player frame, two tiles above its health bar: you on top (only while in a
-- group), then party1-4. In a raid the raid grid (Raid.lua) takes its place.
-- Holding the pick button and tilting the controller picks too (see Arch.lua).
local _, ns = ...

local WIDTH, HEIGHT, GAP = 126, 58, 4
local STYLE = {
    width = WIDTH, height = HEIGHT,
    nameSize = 17, nameY = 2,
    healthTextSize = 16, statusSize = 15, healthTextY = -16, icon = 22,
    dispel = 16, dispelText = 12,
    hot = 12, hotInset = 3, hotGap = 2,
    mana = 5,
}

local db = ns.AddOptions("party", {
    { key = "enabled", kind = "toggle", label = "Party tiles", default = true, reload = true,
      hint = "Off brings back Blizzard's party frames." },
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
      hint = "Every tile as you, to see the layout without a group.", run = function() ns.TogglePartyTest() end },
})
local player = ns.Settings("player")

local members = {}

-- The tiles hang in a column that grows from its top right corner: 56 left
-- of the player frame's health bar, the top two tiles above that bar's top.
-- The tiles are protected, so it only changes out of combat.
local column = CreateFrame("Frame", "HoheUIPartyColumn", ns.root)
column:SetSize(WIDTH, 5 * HEIGHT + 4 * GAP)
ns.partyColumn = column

local function PlaceColumn()
    local scale, playerScale = db.scale, player.scale
    local right = -(ns.player:GetWidth() * playerScale / 2) - 56
    local top = ns.PLAYER_TOP - 20 * playerScale + 2 * (HEIGHT + GAP) * scale
    column:SetScale(scale)
    column:ClearAllPoints()
    column:SetPoint("TOPRIGHT", ns.root, "CENTER", right / scale, top / scale)
end
PlaceColumn()

-- Your own tile shows while you're in a group; the others while their member
-- exists. Both are handled by the game, so they work in combat.
local function Watch(btn)
    if btn.homeUnit == "player" then
        RegisterStateDriver(btn, "visibility", "[group] show; hide")
    else
        RegisterUnitWatch(btn)
    end
end

local function Unwatch(btn)
    if btn.homeUnit == "player" then
        UnregisterStateDriver(btn, "visibility")
    else
        UnregisterUnitWatch(btn)
    end
end

local function CreateMember(slot, unit, name)
    local btn = ns.CreateTile(column, unit, name, STYLE, db)
    btn:SetPoint("TOP", column, "TOP", 0, -(slot - 1) * (HEIGHT + GAP))
    btn.index = slot
    btn.aimable = true -- the gyro pick steps through these (Arch.lua)
    Watch(btn)
    return btn
end

members[1] = CreateMember(1, "player", "HoheUIPartyPlayer")
for i = 1, 4 do
    members[i + 1] = CreateMember(i + 1, "party" .. i, "HoheUIParty" .. i)
end
ns.partyTiles = members

-- Test mode -------------------------------------------------------------------
-- /hoheui party shows every tile as you, to check the layout without a group.

local testing = false

function ns.TogglePartyTest()
    if not db.enabled then return end
    if InCombatLockdown() then
        print("HoheUI: can't change party frames in combat.")
        return
    end
    testing = not testing
    for _, btn in ipairs(members) do
        ns.SetTileUnit(btn, testing and "player" or btn.homeUnit)
        if testing then
            Unwatch(btn)
            btn:Show()
            ns.UpdateTile(btn)
        else
            Watch(btn)
        end
    end
end

ns.AddCommand("party", "preview the party frames", ns.TogglePartyTest)

-- Settings ---------------------------------------------------------------------

local function RefreshAll()
    for _, btn in ipairs(members) do
        if btn:IsVisible() then ns.UpdateTile(btn) end
    end
end

ns.Watch("party", "enabled", function(on)
    if on then return end
    for _, btn in ipairs(members) do ns.StopTile(btn) end
    ns.AfterCombat(function()
        for _, btn in ipairs(members) do
            Unwatch(btn)
            btn:Hide()
        end
    end)
end)
ns.Watch("party", "scale", function() ns.AfterCombat(PlaceColumn) end)
ns.Watch("player", "scale", function() ns.AfterCombat(PlaceColumn) end)
for _, key in ipairs({ "grow", "hots", "dispel", "mana", "healthText" }) do ns.Watch("party", key, RefreshAll) end

ns.HideBlizzard(PartyFrame, "party")
ns.HideBlizzard(CompactPartyFrame, "party")
