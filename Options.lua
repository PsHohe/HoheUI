-- Settings window: /hoheui, a key set on its Keybinds page, or the button
-- under Options > AddOns > HoheUI. A module per entry in the list on the
-- left; a module of several pages (Unit Frames) gets a tab per page across
-- the top. Each page is drawn from the options its part adds (see
-- Config.lua): a switch, a slider, a key, a set of choices or a button per row. Changes show at once, except turning a whole part on or off, which
-- waits for a reload; the footer offers one.
local addonName, ns = ...

local C = ns.COLORS

local WIDTH, HEIGHT = 640, 500
local HEADER, FOOTER, NAV, TABS = 44, 48, 150, 36
local PAD = 20
local CONTENT = WIDTH - NAV - PAD * 2
local ROW = 34
local CONTROL_WIDTH = 230
local CHOICE_WIDTH = 72
local DIMMED = 0.35
local MODIFIER_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true, LMETA = true, RMETA = true }

ns.GetSection("binds").intro = "Click a key, then press a key or a pad button. Escape cancels; right-click clears."
ns.AddOptions("binds", {
    { key = "options", kind = "bind", label = "Open these settings", default = false, click = "HoheUIOptionsToggle" },
})

-- Widgets ------------------------------------------------------------------------

-- A flat fill with a 1-unit black edge outside it, like the bars.
local function Box(frame, color)
    local edge = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(0, 0, 0, 1)
    local fill = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
    fill:SetAllPoints()
    fill:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    return fill
end

local function CreateButton(parent, width, label, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, 24)
    button.fill = Box(button, ns.TRACK)
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)
    button.text = ns.CreateText(button, 13, ns.FONT_TEXT, C.text)
    button.text:SetPoint("CENTER")
    button.text:SetText(label)
    if onClick then button:SetScript("OnClick", onClick) end
    return button
end

-- A switch: the track lights up and the knob moves right when on.
local function CreateToggle(parent, set)
    local toggle = CreateFrame("Button", nil, parent)
    toggle:SetSize(36, 18)
    local track = Box(toggle, ns.TRACK)
    local knob = toggle:CreateTexture(nil, "ARTWORK")
    knob:SetSize(14, 14)
    function toggle:SetValue(on)
        self.value = on
        local color = on and C.accent or ns.TRACK
        track:SetColorTexture(color[1], color[2], color[3], 1)
        local knobColor = on and ns.HEALTH_FILL or C.muted
        knob:SetColorTexture(knobColor[1], knobColor[2], knobColor[3], 1)
        knob:ClearAllPoints()
        knob:SetPoint(on and "RIGHT" or "LEFT", on and -2 or 2, 0)
    end
    toggle:SetScript("OnClick", function(self) set(not self.value) end)
    return toggle
end

-- The nearest step, inside the range. Rounded, so a value that lands on the
-- default compares equal to it and isn't saved.
local function Snap(def, value)
    value = math.floor((value - def.min) / def.step + 0.5) * def.step + def.min
    value = math.max(def.min, math.min(def.max, value))
    return tonumber(string.format("%.4f", value))
end

local function FormatValue(def, value)
    if def.percent then return string.format("%d%%", math.floor(value * 100 + 0.5)) end
    return tostring(value)
end

-- A slider between - and + buttons (easier with a pad's pointer), the value
-- after them. The wheel steps it too.
local function CreateRange(parent, def, set)
    local range = CreateFrame("Frame", nil, parent)
    range:SetSize(CONTROL_WIDTH, 20)

    local value = ns.CreateText(range, 13, ns.FONT_NUMBER, C.text)
    value:SetPoint("RIGHT")
    value:SetWidth(44)
    value:SetJustifyH("RIGHT")

    local minus = CreateButton(range, 20, "-", function() set(Snap(def, range.value - def.step)) end)
    minus:SetHeight(20)
    minus:SetPoint("LEFT")
    local plus = CreateButton(range, 20, "+", function() set(Snap(def, range.value + def.step)) end)
    plus:SetHeight(20)
    plus:SetPoint("RIGHT", value, "LEFT", -8, 0)

    local slider = CreateFrame("Slider", nil, range)
    slider:SetPoint("LEFT", minus, "RIGHT", 10, 0)
    slider:SetPoint("RIGHT", plus, "LEFT", -10, 0)
    slider:SetHeight(20)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(def.min, def.max)
    slider:SetValueStep(def.step)
    slider:SetObeyStepOnDrag(true)
    slider:SetThumbTexture(ns.TEXTURE)
    local thumb = slider:GetThumbTexture()
    thumb:SetSize(8, 18)
    thumb:SetVertexColor(C.text[1], C.text[2], C.text[3])
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(4)
    track:SetColorTexture(ns.TRACK[1], ns.TRACK[2], ns.TRACK[3], 1)
    local fill = slider:CreateTexture(nil, "BORDER")
    fill:SetPoint("LEFT", track, "LEFT")
    fill:SetPoint("RIGHT", thumb, "CENTER")
    fill:SetHeight(4)
    fill:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)

    slider:SetScript("OnValueChanged", function(_, new, userInput)
        if userInput then set(Snap(def, new)) end
    end)
    slider:EnableMouseWheel(true)
    slider:SetScript("OnMouseWheel", function(_, delta) set(Snap(def, range.value + delta * def.step)) end)

    function range:SetValue(new)
        self.value = new
        slider:SetValue(new)
        value:SetText(FormatValue(def, new))
    end
    return range
end

-- Buttons side by side, one per choice; the chosen one lights up.
local function CreateChoice(parent, def, set)
    local choice = CreateFrame("Frame", nil, parent)
    choice:SetSize(#def.choices * (CHOICE_WIDTH + 4) - 4, 24)
    choice.buttons = {}
    for i, option in ipairs(def.choices) do
        local button = CreateButton(choice, CHOICE_WIDTH, option.text, function() set(option.value) end)
        button:SetPoint("LEFT", (i - 1) * (CHOICE_WIDTH + 4), 0)
        button.value = option.value
        choice.buttons[i] = button
    end
    function choice:SetValue(value)
        for _, button in ipairs(self.buttons) do
            local on = button.value == value
            local fill = on and C.accent or ns.TRACK
            button.fill:SetColorTexture(fill[1], fill[2], fill[3], 1)
            local text = on and ns.HEALTH_FILL or C.text
            button.text:SetTextColor(text[1], text[2], text[3])
        end
    end
    return choice
end

-- Key capture: one bind button at a time listens for the next key or pad
-- button. Not in combat, when keys can't be bound.
local capturing

local function StopCapture()
    local button = capturing
    if not button then return end
    capturing = nil
    button:EnableKeyboard(false)
    if button.EnableGamePadButton then button:EnableGamePadButton(false) end
    button:SetValue(button.value)
end

local function CreateBind(parent, def, set)
    local button = CreateButton(parent, 170, "")
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- A key pressed with modifiers keeps them, unless the action is bound
    -- under every modifier anyway.
    local function Take(key)
        local prefix = ""
        if not def.anyModifier then
            prefix = (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "")
                .. (IsShiftKeyDown() and "SHIFT-" or "")
        end
        StopCapture()
        set(prefix .. key)
    end

    button:SetScript("OnClick", function(self, mouse)
        local was = capturing
        StopCapture()
        if mouse == "RightButton" then
            set(false)
        elseif was ~= self and not InCombatLockdown() then
            capturing = self
            self.text:SetText("Press a key...")
            self.text:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
            self:EnableKeyboard(true)
            if self.EnableGamePadButton then self:EnableGamePadButton(true) end
        end
    end)
    button:SetScript("OnKeyDown", function(_, key)
        if MODIFIER_KEYS[key] then return end
        if key == "ESCAPE" then
            StopCapture()
        else
            Take(key)
        end
    end)
    button:SetScript("OnGamePadButtonDown", function(_, key) Take(key) end)

    function button:SetValue(key)
        self.value = key
        if capturing == self then return end
        self.text:SetText(ns.KeyText(key))
        local color = key and C.text or C.muted
        self.text:SetTextColor(color[1], color[2], color[3])
    end
    return button
end

-- The window ------------------------------------------------------------------------

local f = CreateFrame("Frame", "HoheUIOptions", ns.root)
f:SetSize(WIDTH, HEIGHT)
f:SetPoint("CENTER")
f:SetFrameStrata("FULLSCREEN_DIALOG")
f:SetToplevel(true)
f:EnableMouse(true)
f:SetMovable(true)
f:SetClampedToScreen(true)
f:Hide()
Box(f, { ns.PANEL[1], ns.PANEL[2], ns.PANEL[3], 0.97 })
tinsert(UISpecialFrames, "HoheUIOptions") -- Escape closes it

local header = CreateFrame("Frame", nil, f)
header:SetPoint("TOPLEFT")
header:SetPoint("TOPRIGHT")
header:SetHeight(HEADER)
header:EnableMouse(true)
header:RegisterForDrag("LeftButton")
header:SetScript("OnDragStart", function() f:StartMoving() end)
header:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

local title = ns.CreateText(header, 18, ns.FONT_TEXT, C.text)
title:SetPoint("LEFT", PAD, 0)
title:SetText("HoheUI")
local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local version = ns.CreateText(header, 12, ns.FONT_NUMBER, C.muted)
version:SetPoint("LEFT", title, "RIGHT", 8, -1)
version:SetText(getMetadata and getMetadata(addonName, "Version") or "")

local close = CreateFrame("Button", nil, header)
close:SetSize(HEADER, HEADER)
close:SetPoint("RIGHT")
close.text = ns.CreateText(close, 22, ns.FONT_NUMBER, C.muted)
close.text:SetPoint("CENTER")
close.text:SetText("×")
close:SetScript("OnEnter", function(self) self.text:SetTextColor(C.text[1], C.text[2], C.text[3]) end)
close:SetScript("OnLeave", function(self) self.text:SetTextColor(C.muted[1], C.muted[2], C.muted[3]) end)
close:SetScript("OnClick", function() f:Hide() end)

-- A black line along one edge ("TOP" or "BOTTOM") of `frame`.
local function Line(frame, edge)
    local line = frame:CreateTexture(nil, "BORDER")
    line:SetHeight(1)
    line:SetPoint(edge .. "LEFT", frame, edge .. "LEFT")
    line:SetPoint(edge .. "RIGHT", frame, edge .. "RIGHT")
    line:SetColorTexture(0, 0, 0, 1)
end
Line(header, "BOTTOM")

local nav = CreateFrame("Frame", nil, f)
nav:SetPoint("TOPLEFT", 0, -HEADER)
nav:SetPoint("BOTTOMLEFT")
nav:SetWidth(NAV)
local navFill = nav:CreateTexture(nil, "BACKGROUND")
navFill:SetAllPoints()
navFill:SetColorTexture(0, 0, 0, 0.25)

local footer = CreateFrame("Frame", nil, f)
footer:SetPoint("BOTTOMLEFT", NAV, 0)
footer:SetPoint("BOTTOMRIGHT")
footer:SetHeight(FOOTER)
Line(footer, "TOP")

-- The tabs of a module with several pages, under the header.
local tabStrip = CreateFrame("Frame", nil, f)
tabStrip:SetPoint("TOPLEFT", NAV, -HEADER)
tabStrip:SetPoint("TOPRIGHT", 0, -HEADER)
tabStrip:SetHeight(TABS)
local tabFill = tabStrip:CreateTexture(nil, "BACKGROUND")
tabFill:SetAllPoints()
tabFill:SetColorTexture(0, 0, 0, 0.12)
Line(tabStrip, "BOTTOM")

-- The page scrolls with the wheel when it's taller than the window.
local scroll = CreateFrame("ScrollFrame", nil, f)
scroll:SetPoint("TOPLEFT", NAV + PAD, -HEADER - 8)
scroll:SetPoint("BOTTOMRIGHT", -PAD, FOOTER + 1)
local scrollChild = CreateFrame("Frame", nil, scroll)
scrollChild:SetSize(CONTENT, 1)
scroll:SetScrollChild(scrollChild)
scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(self, delta)
    local most = math.max(0, scrollChild:GetHeight() - self:GetHeight())
    self:SetVerticalScroll(math.max(0, math.min(most, self:GetVerticalScroll() - delta * 40)))
end)

-- Pages ----------------------------------------------------------------------------

local pages = {}
local navButtons = {}
local tabButtons = {} -- by module key, a list of tabs
local lastPage = {} -- by module key, the page it last showed
local current
local Refresh

-- An option is greyed out while its page's part, or the part it `needs`, is off.
local function Usable(section, def)
    if def.key == "enabled" then return true end
    if section.defs.enabled and not section.db.enabled then return false end
    return not def.needs or ns.Settings(def.needs).enabled
end

local function CreateRow(page, section, def)
    local row = CreateFrame("Frame", nil, page)
    row:SetWidth(CONTENT)
    row.section, row.def = section, def
    if def.kind == "header" then
        row:SetHeight(36)
        local label = ns.CreateText(row, 12, ns.FONT_TEXT, C.accent)
        label:SetPoint("BOTTOMLEFT", 0, 6)
        label:SetText(def.label:upper())
        return row
    end

    local label = ns.CreateText(row, 14, ns.FONT_TEXT, C.text)
    label:SetPoint("LEFT", row, "TOPLEFT", 0, -ROW / 2)
    label:SetWidth(CONTENT - CONTROL_WIDTH - 16)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetText(def.label)
    local height = ROW
    if def.hint then
        local hint = ns.CreateText(row, 11, ns.FONT_TEXT, C.muted)
        hint:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -3)
        hint:SetWidth(CONTENT - CONTROL_WIDTH - 16)
        hint:SetJustifyH("LEFT")
        hint:SetText(def.hint)
        height = ROW + hint:GetStringHeight() + 2
    end
    row:SetHeight(height)

    local divider = row:CreateTexture(nil, "BACKGROUND")
    divider:SetHeight(1)
    divider:SetPoint("BOTTOMLEFT")
    divider:SetPoint("BOTTOMRIGHT")
    divider:SetColorTexture(1, 1, 1, 0.06)

    local function set(value)
        ns.Set(section.key, def.key, value)
        Refresh()
    end
    local control
    if def.kind == "toggle" then
        control = CreateToggle(row, set)
    elseif def.kind == "range" then
        control = CreateRange(row, def, set)
    elseif def.kind == "bind" then
        control = CreateBind(row, def, set)
    elseif def.kind == "choice" then
        control = CreateChoice(row, def, set)
    elseif def.kind == "button" then
        control = CreateButton(row, 120, def.text or def.label, function() def.run() end)
    end
    if control then control:SetPoint("RIGHT", row, "TOPRIGHT", 0, -ROW / 2) end
    row.control = control

    -- Over a greyed-out row, so its controls can't be used.
    row.blocker = CreateFrame("Frame", nil, row)
    row.blocker:SetAllPoints()
    row.blocker:SetFrameLevel(row:GetFrameLevel() + 10)
    row.blocker:EnableMouse(true)
    row.blocker:Hide()
    return row
end

local function BuildPage(section)
    local page = CreateFrame("Frame", nil, scrollChild)
    page:SetPoint("TOPLEFT")
    page:SetWidth(CONTENT)
    page.rows = {}
    local y = 0
    if section.intro then
        local intro = ns.CreateText(page, 12, ns.FONT_TEXT, C.muted)
        intro:SetPoint("TOPLEFT", 0, -6)
        intro:SetWidth(CONTENT)
        intro:SetJustifyH("LEFT")
        intro:SetText(section.intro)
        y = intro:GetStringHeight() + 14
    end
    for _, def in ipairs(section.options) do
        local row = CreateRow(page, section, def)
        row:SetPoint("TOPLEFT", 0, -y)
        y = y + row:GetHeight()
        page.rows[#page.rows + 1] = row
    end
    page.height = y + 8
    page:SetHeight(page.height)
    return page
end

local reloadNote = ns.CreateText(footer, 12, ns.FONT_TEXT, C.accent)
reloadNote:SetPoint("LEFT", PAD, 0)
reloadNote:SetText("Some changes need a reload.")
local reload = CreateButton(footer, 100, "Reload now", function() ReloadUI() end)
reload:SetPoint("LEFT", reloadNote, "RIGHT", 10, 0)

local defaults = CreateButton(footer, 110, "Page defaults", function()
    StopCapture()
    ns.ResetSection(current)
    Refresh()
end)
defaults:SetPoint("RIGHT", -PAD, 0)

function Refresh()
    local page = pages[current]
    if page then
        for _, row in ipairs(page.rows) do
            if row.blocker then
                if row.control.SetValue then row.control:SetValue(row.section.db[row.def.key]) end
                local usable = Usable(row.section, row.def)
                row:SetAlpha(usable and 1 or DIMMED)
                row.blocker:SetShown(not usable)
            end
        end
    end
    local needsReload = ns.NeedsReload()
    reloadNote:SetShown(needsReload)
    reload:SetShown(needsReload)
end

-- Selected: bright text and the accent bar; otherwise muted.
local function Select(button, selected)
    local color = selected and C.text or C.muted
    button.text:SetTextColor(color[1], color[2], color[3])
    button.bar:SetShown(selected)
end

local function ShowPage(key)
    StopCapture()
    current = key
    local module = ns.GetSection(key).module
    lastPage[module.key] = key
    if not pages[key] then pages[key] = BuildPage(ns.GetSection(key)) end
    for pageKey, page in pairs(pages) do page:SetShown(pageKey == key) end

    local tabs = tabButtons[module.key]
    tabStrip:SetShown(tabs ~= nil)
    for moduleKey, list in pairs(tabButtons) do
        for _, tab in ipairs(list) do
            tab:SetShown(moduleKey == module.key)
            Select(tab, tab.key == key)
        end
    end
    -- Laid out here rather than at load, when the text may not have a width yet.
    local x = PAD - 12
    for _, tab in ipairs(tabs or {}) do
        tab:SetWidth(tab.text:GetStringWidth() + 24)
        tab:SetPoint("LEFT", x, 0)
        x = x + tab:GetWidth()
    end
    scroll:SetPoint("TOPLEFT", NAV + PAD, -HEADER - (tabs and TABS or 0) - 8)

    scrollChild:SetHeight(pages[key].height)
    scroll:SetVerticalScroll(0)
    for _, button in ipairs(navButtons) do Select(button, button.key == module.key) end
    Refresh()
end

for i, module in ipairs(ns.modules) do
    local button = CreateFrame("Button", nil, nav)
    button:SetSize(NAV, 32)
    button:SetPoint("TOPLEFT", 0, -8 - (i - 1) * 32)
    button.key = module.key
    button.text = ns.CreateText(button, 14, ns.FONT_TEXT, C.muted)
    button.text:SetPoint("LEFT", PAD, 0)
    button.text:SetText(module.title)
    button.bar = button:CreateTexture(nil, "ARTWORK")
    button.bar:SetPoint("TOPLEFT")
    button.bar:SetPoint("BOTTOMLEFT")
    button.bar:SetWidth(3)
    button.bar:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.05)
    button:SetScript("OnClick", function() ShowPage(lastPage[module.key] or module.sections[1].key) end)
    navButtons[i] = button

    if #module.sections > 1 then
        local list = {}
        for j, section in ipairs(module.sections) do
            local tab = CreateFrame("Button", nil, tabStrip)
            tab:SetHeight(TABS)
            tab.key = section.key
            tab.text = ns.CreateText(tab, 13, ns.FONT_TEXT, C.muted)
            tab.text:SetPoint("CENTER")
            tab.text:SetText(section.title)
            tab.bar = tab:CreateTexture(nil, "ARTWORK")
            tab.bar:SetPoint("BOTTOMLEFT", 6, 0)
            tab.bar:SetPoint("BOTTOMRIGHT", -6, 0)
            tab.bar:SetHeight(2)
            tab.bar:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1)
            local tabHighlight = tab:CreateTexture(nil, "HIGHLIGHT")
            tabHighlight:SetAllPoints()
            tabHighlight:SetColorTexture(1, 1, 1, 0.05)
            tab:SetScript("OnClick", function() ShowPage(section.key) end)
            list[j] = tab
        end
        tabButtons[module.key] = list
    end
end

f:SetScript("OnShow", function() ShowPage(current or ns.sections[1].key) end)
f:SetScript("OnHide", StopCapture)

function ns.ToggleOptions()
    f:SetShown(not f:IsShown())
end

-- For the "Open these settings" key.
local toggleButton = CreateFrame("Button", "HoheUIOptionsToggle", UIParent)
toggleButton:SetScript("OnClick", ns.ToggleOptions)

local handlers = {}

handlers.PLAYER_REGEN_DISABLED = StopCapture

local events = CreateFrame("Frame")
for event in pairs(handlers) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)

-- Options > AddOns > HoheUI: a pointer to the window.
if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local canvas = CreateFrame("Frame")
    local heading = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 16, -16)
    heading:SetText("HoheUI")
    local about = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    about:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -10)
    about:SetWidth(560)
    about:SetJustifyH("LEFT")
    about:SetText("HoheUI's settings have a window of their own. Type /hoheui, or:")
    local open = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    open:SetSize(180, 24)
    open:SetPoint("TOPLEFT", about, "BOTTOMLEFT", 0, -14)
    open:SetText("Open HoheUI settings")
    open:SetScript("OnClick", function() f:Show() end)
    Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(canvas, "HoheUI"))
end
