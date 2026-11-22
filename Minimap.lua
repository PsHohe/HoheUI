-- Minimap: Blizzard's minimap, squared and framed like the rest of HoheUI in
-- the top right corner. A strip above it shows the clock (Blizzard's own
-- choice of realm or local time, 12 or 24 hours; a click opens its clock
-- settings, alarm and stopwatch). A strip under it names the zone, coloured by its PvP
-- status, and opens the drawer: a grid under the strip that holds the
-- minimap's buttons (tracking, the calendar, the addon compartment and every
-- addon's minimap icon), so none of them sit on the map. The wheel zooms;
-- the day/night dial and the mail icon stay on the map's corners.
-- /hoheui minimap opens the drawer.
local _, ns = ...

local C = ns.COLORS

local MARGIN = 16 -- from the screen's top and right edges
local STRIP = 22
local CELL, GAP, INSET = 28, 4, 6
local DIEL = 30 -- the day/night dial

local db = ns.AddOptions("minimap", {
    { key = "enabled", kind = "toggle", label = "Square minimap", default = true, reload = true,
      hint = "Off brings back Blizzard's round minimap." },
    { key = "size", kind = "range", label = "Size", default = 210, min = 140, max = 320, step = 10 },
    { key = "clock", kind = "toggle", label = "Clock", default = true,
      hint = "Above the map. Click it for the clock settings, alarm and stopwatch." },
    { key = "preview", kind = "button", label = "Drawer", text = "Open / close",
      hint = "The minimap's buttons and every addon's icon.", run = function() ns.ToggleMinimapDrawer() end },
})
ns.AddOptions("binds", {
    { key = "drawer", kind = "bind", label = "Minimap drawer", default = false, click = "HoheUIMinimapDrawerToggle",
      needs = "minimap" },
})

local active = false

local hidden = CreateFrame("Frame")
hidden:Hide()

-- The frame: the clock on top, the map, then the strip, black lines between.
local holder = CreateFrame("Frame", "HoheUIMinimap", ns.root)
holder:SetPoint("TOPRIGHT", ns.root, "TOPRIGHT", -MARGIN, -MARGIN)
holder:Hide()
ns.CreatePanel(holder)

local strip = CreateFrame("Button", nil, holder)
strip:SetPoint("BOTTOMLEFT")
strip:SetPoint("BOTTOMRIGHT")
strip:SetHeight(STRIP)
local highlight = strip:CreateTexture(nil, "HIGHLIGHT")
highlight:SetAllPoints()
highlight:SetColorTexture(1, 1, 1, 0.06)

local divider = holder:CreateTexture(nil, "ARTWORK")
divider:SetPoint("BOTTOMLEFT", strip, "TOPLEFT")
divider:SetPoint("BOTTOMRIGHT", strip, "TOPRIGHT")
divider:SetHeight(1)
divider:SetColorTexture(0, 0, 0, 1)

local count = ns.CreateText(strip, 12, ns.FONT_NUMBER, C.muted)
count:SetPoint("RIGHT", -8, 0)

local zone = ns.CreateText(strip, 12, ns.FONT_TEXT)
zone:SetPoint("LEFT", 8, 0)
zone:SetPoint("RIGHT", count, "LEFT", -8, 0)
zone:SetJustifyH("LEFT")
zone:SetWordWrap(false)

local ZONE_COLORS = {
    sanctuary = { 0.41, 0.8, 0.94 },
    friendly = C.friendly,
    hostile = C.hostile,
    combat = C.hostile,
    arena = C.hostile,
    contested = C.neutral,
}

local function UpdateZone()
    local pvp = C_PvP and C_PvP.GetZonePVPInfo and C_PvP.GetZonePVPInfo()
    local color = ZONE_COLORS[pvp] or C.text
    zone:SetTextColor(color[1], color[2], color[3])
    zone:SetText(GetMinimapZoneText())
end

-- The clock ---------------------------------------------------------------------------

local clock = CreateFrame("Button", nil, holder)
clock:SetPoint("TOPLEFT")
clock:SetPoint("TOPRIGHT")
clock:SetHeight(STRIP)
local clockHighlight = clock:CreateTexture(nil, "HIGHLIGHT")
clockHighlight:SetAllPoints()
clockHighlight:SetColorTexture(1, 1, 1, 0.06)

local clockLine = clock:CreateTexture(nil, "ARTWORK")
clockLine:SetPoint("TOPLEFT", clock, "BOTTOMLEFT")
clockLine:SetPoint("TOPRIGHT", clock, "BOTTOMRIGHT")
clockLine:SetHeight(1)
clockLine:SetColorTexture(0, 0, 0, 1)

local clockText = ns.CreateText(clock, 13, ns.FONT_NUMBER)
clockText:SetPoint("CENTER")

local function UpdateClock()
    local text = GameTime_GetTime(true)
    if clockText:GetText() ~= text then clockText:SetText(text) end
end

clock:SetScript("OnClick", function() ToggleTimeManager() end)
clock:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTime_UpdateTooltip()
    GameTooltip:Show()
end)
clock:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- No event marks the minute, so it checks every second while it's shown.
local ticker
clock:SetScript("OnShow", function()
    UpdateClock()
    if not ticker then ticker = C_Timer.NewTicker(1, UpdateClock) end
end)
clock:SetScript("OnHide", function()
    if ticker then ticker:Cancel() end
    ticker = nil
end)

-- The drawer -----------------------------------------------------------------------
-- Blizzard's buttons first, then the addons' icons by name. Only shown ones
-- get a cell, and showing or hiding one lays the grid out again.

local drawer = CreateFrame("Frame", "HoheUIMinimapDrawer", holder)
drawer:SetPoint("TOPRIGHT", holder, "BOTTOMRIGHT", 0, -GAP)
drawer:SetFrameStrata("MEDIUM")
drawer:Hide()
ns.CreatePanel(drawer)

local blizzardItems, addonItems = {}, {}
local taken = {}
local cells = {}

local function Cell(i)
    local cell = cells[i]
    if not cell then
        cell = CreateFrame("Frame", nil, drawer)
        cell:SetSize(CELL, CELL)
        local bg = cell:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(ns.TRACK[1], ns.TRACK[2], ns.TRACK[3], ns.TRACK[4])
        cells[i] = cell
    end
    return cell
end

-- Addons' icons have SetPoint and ClearAllPoints switched off (see Take), so
-- they're moved with the widget's own methods.
local function Anchor(frame, ...)
    local methods = getmetatable(frame).__index
    methods.ClearAllPoints(frame)
    methods.SetPoint(frame, ...)
end

local function UpdateCount(shown)
    local color = drawer:IsShown() and C.accent or C.muted
    count:SetTextColor(color[1], color[2], color[3])
    count:SetText(shown)
end

local function Layout()
    local shown = {}
    for _, list in ipairs({ blizzardItems, addonItems }) do
        for _, frame in ipairs(list) do
            if frame:IsShown() then shown[#shown + 1] = frame end
        end
    end
    local width = db.size
    local columns = math.max(1, math.floor((width - 2 * INSET + GAP) / (CELL + GAP)))
    local left = (width - (columns * (CELL + GAP) - GAP)) / 2
    for i, frame in ipairs(shown) do
        local cell = Cell(i)
        local column, row = (i - 1) % columns, math.floor((i - 1) / columns)
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", left + column * (CELL + GAP), -(INSET + row * (CELL + GAP)))
        cell:Show()
        Anchor(frame, "CENTER", cell, "CENTER")
        frame:SetFrameLevel(cell:GetFrameLevel() + 2)
    end
    for i = #shown + 1, #cells do cells[i]:Hide() end
    local rows = math.max(1, math.ceil(#shown / columns))
    drawer:SetSize(width, rows * (CELL + GAP) - GAP + 2 * INSET)
    UpdateCount(#shown)
end

local layoutScheduled = false
local function ScheduleLayout()
    if layoutScheduled then return end
    layoutScheduled = true
    C_Timer.After(0, function()
        layoutScheduled = false
        Layout()
    end)
end

-- The round art around addon icons: the gold ring and the dark disc.
local RING_FILES = { [136430] = true, [136467] = true }

local function IsRing(texture)
    local file = texture:GetTexture()
    if type(file) == "number" then return RING_FILES[file] end
    if type(file) ~= "string" then return false end
    file = file:lower()
    return file:find("trackingborder", 1, true) ~= nil or file:find("minimap-background", 1, true) ~= nil
end

-- Squares an addon's icon: no ring, the icon filling the cell, a flat
-- highlight.
local function Skin(button)
    for _, region in ipairs({ button:GetRegions() }) do
        if region:IsObjectType("Texture") and IsRing(region) then region:SetAlpha(0) end
    end
    button:SetSize(CELL, CELL)
    local name = button:GetName()
    local icon = button.icon or button.Icon or (name and _G[name .. "Icon"])
    if icon and icon.SetPoint then
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", 3, -3)
        icon:SetPoint("BOTTOMRIGHT", -3, 3)
    end
    if button:IsObjectType("Button") then
        button:SetHighlightTexture(ns.TEXTURE)
        local glow = button:GetHighlightTexture()
        glow:SetAllPoints()
        glow:SetVertexColor(1, 1, 1, 0.12)
    end
end

local function NoOp() end

-- Moves a button into the drawer. Blizzard's keep their own methods (an
-- addon's function on them would taint) and are put back after Blizzard
-- moves them; an addon's icon can't be moved, reparented or dragged by its
-- addon any more.
local function Take(frame, blizzard)
    if not frame or taken[frame] then return end
    taken[frame] = true
    frame:SetParent(drawer)
    frame:SetFrameStrata(drawer:GetFrameStrata())
    if blizzard then
        local size = math.max(frame:GetWidth(), frame:GetHeight(), 1)
        frame:SetScale(math.min(1, (CELL - 2) / size))
        blizzardItems[#blizzardItems + 1] = frame
    else
        Skin(frame)
        frame:RegisterForDrag()
        frame:SetScript("OnDragStart", nil)
        frame:SetScript("OnDragStop", nil)
        frame.SetPoint, frame.ClearAllPoints, frame.SetParent = NoOp, NoOp, NoOp
        addonItems[#addonItems + 1] = frame
        table.sort(addonItems, function(a, b) return a:GetName() < b:GetName() end)
    end
    frame:HookScript("OnShow", ScheduleLayout)
    frame:HookScript("OnHide", ScheduleLayout)
    ScheduleLayout()
end

-- An addon's icon: LibDBIcon's, or any button named like a minimap button.
-- Pins on the map (gathering nodes, waypoints) don't match.
local function IsAddonIcon(frame)
    if taken[frame] or not frame:IsObjectType("Button") then return false end
    local name = frame:GetName()
    if not name or name == "ExpansionLandingPageMinimapButton" then return false end
    if name:find("^LibDBIcon10_") then return true end
    name = name:lower()
    return name:find("minimapbutton", 1, true) ~= nil or name:find("minimap_button", 1, true) ~= nil
end

local libDBIcon

local function Scan()
    for _, parent in ipairs({ Minimap, MinimapBackdrop }) do
        for _, child in ipairs({ parent:GetChildren() }) do
            if IsAddonIcon(child) then Take(child) end
        end
    end
    -- LibDBIcon says when an addon makes an icon after the scans.
    local lib = not libDBIcon and LibStub and LibStub("LibDBIcon-1.0", true)
    if lib and lib.RegisterCallback then
        libDBIcon = lib
        lib.RegisterCallback(drawer, "LibDBIcon_IconCreated", function(_, button) Take(button) end)
    end
end

local scanScheduled = false
local function ScheduleScan()
    if scanScheduled then return end
    scanScheduled = true
    C_Timer.After(0, function()
        scanScheduled = false
        Scan()
    end)
end

function ns.ToggleMinimapDrawer()
    if not active then return end
    if drawer:IsShown() then
        drawer:Hide()
    else
        Scan()
        Layout()
        drawer:Show()
    end
    UpdateCount(count:GetText())
end

strip:SetScript("OnClick", ns.ToggleMinimapDrawer)
local toggle = CreateFrame("Button", "HoheUIMinimapDrawerToggle", UIParent)
toggle:SetScript("OnClick", ns.ToggleMinimapDrawer)
ns.AddCommand("minimap", "open the minimap drawer", ns.ToggleMinimapDrawer)

-- The map ---------------------------------------------------------------------------

-- Blizzard puts these back where its round frame wants them when the Edit
-- Mode layout loads or the map rotates, so they're placed again after.
local function PlaceBlizzard()
    Minimap:SetMaskTexture(ns.TEXTURE)
    MinimapCompassTexture:SetAlpha(0)
    MinimapCompassTextureUnderlay:SetAlpha(0)

    local indicator = MinimapCluster.IndicatorFrame
    if indicator then
        indicator:SetParent(holder)
        indicator:ClearAllPoints()
        indicator:SetPoint("BOTTOMLEFT", Minimap, "BOTTOMLEFT", 2, 2)
        indicator:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    end

    local diel = MinimapCluster.DielFrame
    if diel then
        diel:SetParent(holder)
        diel:SetScale(DIEL / math.max(diel:GetWidth(), 1))
        diel:ClearAllPoints()
        diel:SetPoint("TOPRIGHT", Minimap, "TOPRIGHT", -2 / diel:GetScale(), -2 / diel:GetScale())
        diel:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    end

    ScheduleLayout()
end

local function Resize()
    local size = db.size
    local top = db.clock and STRIP + 1 or 0
    clock:SetShown(db.clock)
    holder:SetSize(size, top + size + 1 + STRIP)
    Minimap:ClearAllPoints()
    Minimap:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -top)
    Minimap:SetSize(size, size)
    -- The map only redraws at its new size once the zoom changes.
    local zoom = Minimap:GetZoom()
    Minimap:SetZoom(zoom > 0 and zoom - 1 or zoom + 1)
    Minimap:SetZoom(zoom)
    Layout()
end

-- Indoors some maps are drawn by Blizzard_HybridMinimap, with its own mask.
local function SquareHybrid()
    if HybridMinimap and HybridMinimap.CircleMask then
        HybridMinimap.CircleMask:SetTexture(ns.TEXTURE)
    end
end

-- Blizzard's click handler only pings inside the old circle; the corners
-- are pinged here.
local function PingCorner(self)
    local x, y = GetCursorPosition()
    local scale = self:GetEffectiveScale()
    local cx, cy = self:GetCenter()
    x, y = x / scale - cx, y / scale - cy
    if math.sqrt(x * x + y * y) >= self:GetWidth() / 2 then self:PingLocation(x, y) end
end

local events = CreateFrame("Frame")
local handlers = {}

handlers.ZONE_CHANGED = UpdateZone
handlers.ZONE_CHANGED_INDOORS = UpdateZone
handlers.ZONE_CHANGED_NEW_AREA = UpdateZone

function handlers.PLAYER_ENTERING_WORLD()
    UpdateZone()
    ScheduleScan()
end

function handlers.ADDON_LOADED(name)
    if name == "Blizzard_HybridMinimap" then SquareHybrid() end
    ScheduleScan()
end

events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)

local function Setup()
    if not (Minimap and MinimapCluster) then return end
    active = true
    holder:Show()

    Minimap:SetParent(holder)
    Minimap:SetFrameStrata(holder:GetFrameStrata())
    Minimap:SetFrameLevel(holder:GetFrameLevel() + 1)
    Minimap:SetScale(1)
    -- No rings around quest and dig-site areas: they'd draw the old circle.
    Minimap:SetQuestBlobRingScalar(0)
    Minimap:SetQuestBlobRingAlpha(0)
    Minimap:SetTaskBlobRingScalar(0)
    Minimap:SetTaskBlobRingAlpha(0)
    Minimap:SetArchBlobRingScalar(0)
    Minimap:SetArchBlobRingAlpha(0)
    Minimap:HookScript("OnMouseUp", PingCorner)
    -- The wheel zooms, so no zoom buttons on the map.
    for _, button in ipairs({ Minimap.ZoomIn, Minimap.ZoomOut }) do button:SetParent(hidden) end

    Take(MinimapCluster.Tracking, true)
    Take(GameTimeFrame, true)
    Take(AddonCompartmentFrame, true)
    Take(MinimapBackdrop.ExternalEventURLButton, true)

    for _, method in ipairs({ "UpdateMinimapConfig", "SetHeaderUnderneath", "SetEditModeScale" }) do
        hooksecurefunc(MinimapCluster, method, PlaceBlizzard)
    end
    PlaceBlizzard()
    SquareHybrid()
    Resize()

    -- What other addons read to place icons around the map.
    if not GetMinimapShape then
        function GetMinimapShape() return "SQUARE" end
    end

    for event in pairs(handlers) do events:RegisterEvent(event) end
    UpdateZone()
    Scan()
end

-- Settings ---------------------------------------------------------------------

ns.Watch("minimap", "enabled", function(on)
    if on then ns.AfterCombat(Setup) end
end)
for _, key in ipairs({ "size", "clock" }) do
    ns.Watch("minimap", key, function()
        if active then Resize() end
    end)
end

-- Blizzard's round frame, zone button and header: the square map replaces them.
ns.HideBlizzard(MinimapCluster, "minimap")
