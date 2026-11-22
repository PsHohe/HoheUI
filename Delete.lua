-- Deleting a good item with the pad: the game's button sequence gets its
-- buttons.
--
-- In gamepad mode the game wants Y, LB, A, X, RB before the Yes on a good
-- item's delete popup unlocks (DELETE_GOOD_ITEM_GAMEPAD, GameDialog.lua's
-- GamepadSequence). The sequence reads those through the game's own binds,
-- but Controller Forever's binds sit on top of them (it only lets go of A),
-- so the presses never reach it. While a popup waits on its sequence, a
-- claim above every CF bind leaves those five buttons to the game; it lets
-- go when the popup closes. Any popup with a sequence gets this, so
-- unlearning a profession does too.
--
-- HoheUI must not unlock Yes itself: the delete (C_Item.DeleteItem) is
-- restricted, and a Yes enabled by addon code was tested not to delete
-- (10-22). The sequence, the unlock and the delete all stay Blizzard's.
--
-- Blizzard bug (10-22): the sequence never resets once it's done
-- (InputSequence.lua only resets on a wrong press, which errors first), so
-- the popup's next sequence starts past its end and every press throws.
-- Resetting it from here would make the game's sequence code run as ours,
-- and it ends by changing the game's gamepad binding stack, which is what
-- left Controller Forever's LT / RT layers blocked in fights. So a stuck
-- sequence gets a strip offering a reload instead, and its buttons go
-- nowhere.
local _, ns = ...

-- Y, LB, A, X, RB, held with any modifier.
local KEYS = { "PAD4", "PADLSHOULDER", "PAD1", "PAD3", "PADRSHOULDER" }
local RELOAD_KEY = "PAD1"
local MODIFIERS = { "", "SHIFT-", "ALT-", "ALT-SHIFT-", "CTRL-", "CTRL-SHIFT-", "CTRL-ALT-", "CTRL-ALT-SHIFT-" }

ns.AddOptions("delete", {
    { key = "enabled", kind = "toggle", label = "Delete button sequence", default = true, reload = true,
      hint = "Leaves Y, LB, A, X, RB to the game while a popup asks for its button sequence, such as deleting a good item." },
})

-- A pad button's glyph, drawn by Controller Forever when it's there.
local function Face(face)
    local bar = ControllerForever and ControllerForever.RuleBar
    if bar and bar.faceMarkup then return bar.faceMarkup(face, 14) end
    return face
end

-- The reload strip, under a stuck popup. Named, so A can click it.
local strip = CreateFrame("Button", "HoheUIDeleteReload", UIParent)
strip:SetSize(360, 46)
strip:SetFrameStrata("FULLSCREEN_DIALOG")
strip:RegisterForClicks("AnyUp")
strip:SetScript("OnClick", function()
    if not InCombatLockdown() then ReloadUI() end
end)
strip:Hide()
ns.CreatePanel(strip)
strip.label = ns.CreateText(strip, 13)
strip.label:SetPoint("CENTER")
strip.label:SetText("The game's button sequence works once per session.\n"
    .. Face("A") .. " Reload, then delete again")

-- A button that does nothing, for the stuck sequence's other buttons.
CreateFrame("Button", "HoheUIDeleteIdle", UIParent)

local dialog -- the popup whose sequence the claim is for
local claim
local bound -- "game", "stuck" or nil

-- Without Controller Forever nothing sits on the game's binds, so there's
-- nothing to do.
local function Bind(want)
    if InCombatLockdown() or want == bound then return end
    local binds = ControllerForever and ControllerForever.Binds
    if not (binds and binds.claimant) then return end
    bound = want
    claim = claim or binds:claimant("HoheUIDelete", binds.PRIORITY.gamewindow + 6, { overGame = true, outOfFight = true })
    if want then
        local map = {}
        for _, key in ipairs(KEYS) do
            local action = false -- left to the game
            if want == "stuck" then
                action = key == RELOAD_KEY and "CLICK HoheUIDeleteReload:LeftButton" or "CLICK HoheUIDeleteIdle:LeftButton"
            end
            for _, modifier in ipairs(MODIFIERS) do map[modifier .. key] = action end
        end
        claim.replace(map)
    else
        claim.clear()
    end
    claim.commit()
end

-- The popup shows its button sequence.
local function Waiting(popup)
    local sequence = popup.GamepadSequence
    return popup:IsShown() and sequence and sequence:IsShown()
end

-- Done once already, so the next press throws (read only).
local function Stuck(sequence)
    local index, names = sequence.currentSequenceIndex, sequence.sequenceButtonNames
    return type(index) == "number" and type(names) == "table" and index > #names
end

local function Release()
    dialog = nil
    strip:Hide()
    Bind(nil)
end

local hooked = {}

local function OnPopupShown(which)
    local popup = StaticPopup_FindVisible(which)
    if not popup then return end
    if not hooked[popup] then
        hooked[popup] = true
        popup:HookScript("OnHide", function(self)
            if self == dialog then Release() end
        end)
    end
    -- A frame later, once the popup has set up its sequence.
    C_Timer.After(0, function()
        if not Waiting(popup) then return end
        dialog = popup
        if Stuck(popup.GamepadSequence) then
            strip:ClearAllPoints()
            strip:SetPoint("TOP", popup, "BOTTOM", 0, -8)
            strip:SetFrameLevel(popup:GetFrameLevel() + 10)
            strip:Show()
            Bind("stuck")
        else
            strip:Hide()
            Bind("game")
        end
    end)
end

local afterFight -- the claim to put back when the fight ends

local handlers = {
    -- Before the lock: the buttons go back to the fight.
    PLAYER_REGEN_DISABLED = function()
        afterFight = bound
        Bind(nil)
    end,
    PLAYER_REGEN_ENABLED = function()
        if dialog and afterFight then Bind(afterFight) end
        afterFight = nil
    end,
}

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)

-- What each sequence button does right now.
ns.AddCommand("delete", "show what the delete sequence's buttons are bound to", function()
    print("HoheUI: sequence buttons " .. (bound and ("claimed (" .. bound .. ")") or "not claimed")
        .. (dialog and ", popup " .. tostring(dialog.which) or ", no popup"))
    for _, key in ipairs(KEYS) do
        print("HoheUI:   " .. key .. " = " .. tostring(GetBindingAction(key, true)))
    end
end)

-- Settings ---------------------------------------------------------------------------

ns.Watch("delete", "enabled", function(on)
    if not on then return end
    hooksecurefunc("StaticPopup_Show", OnPopupShown)
    for event in pairs(handlers) do events:RegisterEvent(event) end
end)
