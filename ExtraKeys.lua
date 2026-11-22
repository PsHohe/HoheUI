-- Extra keys: up to four keys with actions of HoheUI's (Steam Input sends the
-- controller's back buttons as F6, F7...). Each key has three actions: its
-- own, one while LT is held and one while RT is held. A small row on the HUD
-- shows what each key does right now and swaps its icons while a trigger is
-- held. Shift and Ctrl on a keyboard do the same as LT and RT.
--
-- The actions live in the game's action slots 169-180 (Action Bar 8), so
-- they're set up the usual way: drag a spell, item or macro onto a button
-- (hold LT or RT, or Shift or Ctrl, to fill that action), drag it off to
-- clear it. If Action Bar 8 is on in Edit Mode it shows the same twelve.
--
-- Which action a press uses is decided by secure code at the moment of the
-- press, from the controller's own state (GetGamePadState), so it works in
-- combat and whether or not the triggers are also Shift or Ctrl. Nothing here
-- changes the game's controller settings or what the triggers do on their
-- own. Only the key fires an action: a mouse click on a button does nothing,
-- so dragging never casts.
--
-- The keys are set on the Keybinds page. /hoheui keys reports what they do.
local addonName, ns = ...

local C = ns.COLORS
local IsSecret = ns.IsSecret

local COUNT = 4
local FIRST_SLOT = 169 -- Action Bar 8
local SIZE = 40
local GAP = 6
local INSET = 1
local POLL = 0.05 -- seconds between looks at the triggers, for the icons
local LAYER_TEXT = { "", "LT", "RT" }
local DEFAULT_KEYS = { "F6", "F7", false, false }

local db = ns.AddOptions("keys", {
    { key = "enabled", kind = "toggle", label = "Extra keys", default = true, reload = true,
      hint = "Keys with an action of their own and another while LT or RT is held. Set the keys on the Keybinds page." },
    { key = "x", kind = "range", label = "Across", default = 0, min = -900, max = 900, step = 10 },
    { key = "y", kind = "range", label = "Up", default = -380, min = -520, max = 500, step = 10,
      hint = "Where the row's top centre sits, in 1080ths of the screen from its centre." },
})

local bindOptions = { { kind = "header", label = "Extra keys" } }
for i = 1, COUNT do
    bindOptions[#bindOptions + 1] = {
        key = "extra" .. i, kind = "bind", label = "Extra key " .. i, default = DEFAULT_KEYS[i],
        click = "HoheUIExtraKey" .. i, button = "Key", anyModifier = true, needs = "keys",
        hint = i == 1 and "Hold LT or RT while pressing a key for its other actions." or nil,
    }
end
local binds = ns.AddOptions("binds", bindOptions)

-- The game's action calls, where this client keeps them.
local AB = C_ActionBar or {}
local GetTexture = GetActionTexture or AB.GetActionTexture
local GetCount = GetActionCount or AB.GetActionCount
local IsUsable = IsUsableAction or AB.IsUsableAction
local IsConsumable = IsConsumableAction or AB.IsConsumableAction
local IsStackable = IsStackableAction or AB.IsStackableAction
local HasActionAt = HasAction or AB.HasAction
local Pickup = PickupAction or AB.PickupAction
local Place = PlaceAction or AB.PlaceAction

local function SlotOf(index, layer)
    return FIRST_SLOT + (layer - 1) * COUNT + index - 1
end

-- The triggers' places in GetGamePadState().buttons (1-based), or nil.
local function PadIndex(binding)
    local get = C_GamePad and C_GamePad.ButtonBindingToIndex
    if not get then return nil end
    local ok, index = pcall(get, binding)
    index = ok and tonumber(index)
    return index and index >= 0 and index + 1 or nil
end
local lt, rt

-- 1 for none, 2 while LT (or Shift) is held, 3 while RT (or Ctrl) is.
-- The secure press code below asks the same questions.
local function CurrentLayer()
    local pad = GetGamePadState and GetGamePadState()
    local held = pad and pad.buttons
    if (held and lt and held[lt]) or IsShiftKeyDown() then return 2 end
    if (held and rt and held[rt]) or IsControlKeyDown() then return 3 end
    return 1
end
local layer = 1

-- The row ----------------------------------------------------------------------------

local bar = CreateFrame("Frame", "HoheUIExtraKeys", ns.root)
bar:SetSize(SIZE, SIZE)
bar:Hide()
bar.layerText = ns.CreateText(bar, 12, ns.FONT_TEXT, C.accent)
bar.layerText:SetPoint("BOTTOM", bar, "TOP", 0, 3)

local buttons = {}

-- Cooldowns are secret in combat: then the game's duration object is handed
-- to the cooldown frame, never read.
local function ShowCooldown(cd, slot)
    local start, duration, enable
    if GetActionCooldown then
        start, duration, enable = GetActionCooldown(slot)
    elseif AB.GetActionCooldown then
        local info = AB.GetActionCooldown(slot)
        if info then start, duration, enable = info.startTime, info.duration, info.isEnabled end
    end
    if IsSecret(start) or IsSecret(duration) or IsSecret(enable) then
        local get = AB.GetActionCooldownDuration
        if get and cd.SetCooldownFromDurationObject
            and pcall(function() cd:SetCooldownFromDurationObject(get(slot)) end) then
            return
        end
        pcall(cd.SetCooldown, cd, start, duration)
    elseif start and duration and duration > 0 and enable ~= 0 and enable ~= false then
        cd:SetCooldown(start, duration)
    else
        cd:Clear()
    end
end

-- How many are left, for an item or reagent action; nothing for a spell.
local function ShowCount(fs, slot)
    local stack = (IsConsumable and IsConsumable(slot)) or (IsStackable and IsStackable(slot))
    if not stack or IsSecret(stack) or not GetCount then
        fs:SetText("")
    elseif not pcall(fs.SetFormattedText, fs, "%d", GetCount(slot)) then
        fs:SetText("")
    end
end

local function Refresh(b)
    local slot = SlotOf(b.index, layer)
    b.slot = slot
    local texture = GetTexture and GetTexture(slot)
    if texture then
        b.icon:SetTexture(texture)
        b.icon:Show()
    else
        b.icon:Hide()
    end
    local usable, noMana
    if IsUsable then usable, noMana = IsUsable(slot) end
    if not texture or IsSecret(usable) or IsSecret(noMana) or usable then
        b.icon:SetVertexColor(1, 1, 1)
    elseif noMana then
        b.icon:SetVertexColor(0.45, 0.5, 1)
    else
        b.icon:SetVertexColor(0.4, 0.4, 0.4)
    end
    if texture then ShowCooldown(b.cooldown, slot) else b.cooldown:Clear() end
    ShowCount(b.count, slot)
    if GameTooltip:IsOwned(b) then b:GetScript("OnEnter")(b) end
end

local function RefreshAll()
    if not bar:IsShown() then return end
    for _, b in ipairs(buttons) do
        if b:IsShown() then Refresh(b) end
    end
end

-- Run as the button, on every press. A mouse click is turned away; a key
-- press picks the action for the triggers held as the key goes down, and
-- the template then uses it on the down or the up (as the game is set).
local PRESS = [[
    if button ~= "Key" then return false end
    if not down then return end
    local pad = GetGamePadState()
    local held = pad and pad.buttons
    local lt, rt = self:GetAttribute("lt"), self:GetAttribute("rt")
    local layer = 0
    if (held and lt and held[lt]) or IsShiftKeyDown() then
        layer = 1
    elseif (held and rt and held[rt]) or IsControlKeyDown() then
        layer = 2
    end
    self:SetAttribute("action", self:GetAttribute("first") + layer * self:GetAttribute("stride"))
]]

for i = 1, COUNT do
    local b = CreateFrame("Button", "HoheUIExtraKey" .. i, bar, "SecureActionButtonTemplate,SecureHandlerBaseTemplate")
    b.index = i
    b:SetSize(SIZE, SIZE)
    b:RegisterForClicks("AnyDown", "AnyUp")
    b:RegisterForDrag("LeftButton")
    b:SetAttribute("type", "action")
    b:SetAttribute("first", SlotOf(i, 1))
    b:SetAttribute("stride", COUNT)
    b:SetAttribute("action", SlotOf(i, 1))
    SecureHandlerWrapScript(b, "OnClick", b, PRESS)
    ns.CreatePanel(b)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", INSET, -INSET)
    b.icon:SetPoint("BOTTOMRIGHT", -INSET, INSET)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cooldown:SetAllPoints(b.icon)
    b.cooldown:SetDrawEdge(false)

    -- Above the cooldown sweep.
    local top = CreateFrame("Frame", nil, b)
    top:SetAllPoints()
    top:SetFrameLevel(b.cooldown:GetFrameLevel() + 2)
    b.keyText = ns.CreateText(top, 10, ns.FONT_NUMBER, C.muted)
    b.keyText:SetPoint("TOPLEFT", 3, -3)
    b.count = ns.CreateText(top, 12, ns.FONT_NUMBER)
    b.count:SetPoint("BOTTOMRIGHT", -3, 3)
    b.flash = top:CreateTexture(nil, "OVERLAY")
    b.flash:SetAllPoints(b.icon)
    b.flash:SetColorTexture(1, 1, 1, 0.25)
    b.flash:Hide()

    local hover = b:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints(b.icon)
    hover:SetColorTexture(1, 1, 1, 0.12)

    -- A press lights the button for a moment.
    b:HookScript("OnClick", function(self, button, down)
        if button ~= "Key" or not down then return end
        self.flash:Show()
        C_Timer.After(0.12, function() self.flash:Hide() end)
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if HasActionAt and HasActionAt(self.slot) and GameTooltip.SetAction then
            GameTooltip:SetAction(self.slot)
        else
            GameTooltip:SetText("Extra key " .. self.index .. (LAYER_TEXT[layer] ~= "" and (" + " .. LAYER_TEXT[layer]) or ""))
            GameTooltip:AddLine("Drag a spell, item or macro here.", 1, 1, 1, true)
            GameTooltip:AddLine("Hold LT or RT (or Shift or Ctrl) to fill its other actions.", 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)

    -- Putting actions on and taking them off waits for combat to end.
    b:SetScript("OnDragStart", function(self)
        if InCombatLockdown() or not Pickup then return end
        Pickup(self.slot)
        RefreshAll()
    end)
    b:SetScript("OnReceiveDrag", function(self)
        if InCombatLockdown() or not Place then return end
        Place(self.slot)
        RefreshAll()
    end)

    buttons[i] = b
end

-- The triggers held are looked at a few times a second while the row shows:
-- the game has no event for a controller button going down.
local elapsed = 0
bar:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < POLL then return end
    elapsed = 0
    local now = CurrentLayer()
    if now == layer then return end
    layer = now
    bar.layerText:SetText(LAYER_TEXT[layer])
    RefreshAll()
end)

-- Placing --------------------------------------------------------------------------
-- The buttons are protected, so they're placed, shown and given the triggers'
-- places out of combat. Only keys that are bound show.

local function Layout()
    local shown = 0
    for i, b in ipairs(buttons) do
        local key = binds["extra" .. i]
        b:SetAttribute("lt", lt)
        b:SetAttribute("rt", rt)
        b:ClearAllPoints()
        if key and db.enabled then
            b:SetPoint("LEFT", bar, "LEFT", shown * (SIZE + GAP), 0)
            b.keyText:SetText(ns.KeyText(key))
            b:Show()
            shown = shown + 1
        else
            b:Hide()
        end
    end
    bar:ClearAllPoints()
    bar:SetPoint("TOP", ns.root, "CENTER", db.x, db.y)
    bar:SetSize(math.max(1, shown * (SIZE + GAP) - GAP), SIZE)
    bar:SetShown(shown > 0)
    RefreshAll()
end

local function Schedule()
    ns.AfterCombat(Layout)
end

local function ReadTriggers()
    lt, rt = PadIndex("PADLTRIGGER"), PadIndex("PADRTRIGGER")
    Schedule()
end

ns.Watch("keys", "enabled", Schedule)
ns.Watch("keys", "x", Schedule)
ns.Watch("keys", "y", Schedule)
for i = 1, COUNT do ns.Watch("binds", "extra" .. i, Schedule) end

-- Events ---------------------------------------------------------------------------

local handlers = {
    PLAYER_LOGIN = ReadTriggers,
    GAME_PAD_CONFIGS_CHANGED = ReadTriggers,
    GAME_PAD_CONNECTED = ReadTriggers,
    GAME_PAD_ACTIVE_CHANGED = ReadTriggers,
    PLAYER_ENTERING_WORLD = RefreshAll,
    ACTIONBAR_SLOT_CHANGED = RefreshAll,
    ACTIONBAR_UPDATE_COOLDOWN = RefreshAll,
    ACTIONBAR_UPDATE_USABLE = RefreshAll,
    SPELL_UPDATE_COOLDOWN = RefreshAll,
    SPELL_UPDATE_USABLE = RefreshAll,
    SPELL_UPDATE_CHARGES = RefreshAll,
    BAG_UPDATE_DELAYED = RefreshAll,
    UPDATE_MACROS = RefreshAll,
}

local events = CreateFrame("Frame")
for event in pairs(handlers) do pcall(events.RegisterEvent, events, event) end
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)

-- /hoheui keys ---------------------------------------------------------------------

local function Probe()
    print("HoheUI: extra keys " .. (db.enabled and "on" or "off"))
    for i = 1, COUNT do
        local key = binds["extra" .. i]
        local line = "  Extra key " .. i .. ": " .. tostring(key or "not bound")
        if key then line = line .. " runs " .. tostring(GetBindingAction(key, true)) end
        local filled = {}
        for l = 1, 3 do
            local slot = SlotOf(i, l)
            filled[l] = (LAYER_TEXT[l] ~= "" and LAYER_TEXT[l] or "own") .. " " .. slot
                .. (HasActionAt and HasActionAt(slot) and " set" or " empty")
        end
        print(line .. " (" .. table.concat(filled, ", ") .. ")")
    end
    print("  LT is pad button " .. tostring(lt) .. ", RT " .. tostring(rt)
        .. "; GetGamePadState " .. (GetGamePadState and "there" or "missing"))
    print("  held now: " .. (LAYER_TEXT[CurrentLayer()] ~= "" and LAYER_TEXT[CurrentLayer()] or "nothing"))
    local cvar = (C_CVar and C_CVar.GetCVar) or GetCVar
    print("  triggers as Shift / Ctrl: " .. tostring(cvar("GamePadEmulateShift")) .. " / "
        .. tostring(cvar("GamePadEmulateCtrl")))
    local bar8 = _G.MultiBar7
    if bar8 and bar8:IsShown() then print("  Action Bar 8 is on, and shows these same actions") end
end

ns.AddCommand("keys", "check the extra keys", Probe)
