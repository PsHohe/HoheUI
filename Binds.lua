-- Keybinds: HoheUI's actions on keys or pad buttons, set on the Keybinds page.
-- An action is a "bind" option whose value is the key (false for none) and
-- whose `click` names the button a press clicks:
--
--   ns.AddOptions("binds", {
--       { key = "pick", kind = "bind", label = "Gyro pick (hold)", default = "PADSOCIAL",
--         click = "HoheUIPickHold", anyModifier = true, needs = "party" },
--   })
--
-- `anyModifier` binds the key under every modifier too, for buttons pressed
-- while a trigger is held. `needs` leaves it unbound while that page's part
-- is turned off. `button` is the mouse button the click arrives as
-- (LeftButton unless given), so a button can tell a key from the mouse.
-- `manual` only keeps the setting: the part binds the key
-- itself, when it wants it (the loot panel takes Select only at times).
--
-- With Controller Forever they're claimed through its binds, above its
-- Healer D-pad (its autorun and held claimants still outrank them), so they
-- win pad buttons it would otherwise take. Without it they're override
-- bindings.
local addonName, ns = ...

ns.MODIFIERS = { "", "SHIFT-", "CTRL-", "ALT-", "CTRL-SHIFT-", "ALT-SHIFT-", "ALT-CTRL-", "ALT-CTRL-SHIFT-" }

local owner = CreateFrame("Frame")
local claim

local function Apply()
    local binds = ControllerForever and ControllerForever.Binds
    if not claim and binds and binds.claimant then
        claim = binds:claimant("HoheUI", binds.PRIORITY.heal + 5)
    end
    local keys = {}
    for _, section in ipairs(ns.sections) do
        for _, def in ipairs(section.options) do
            local key = def.kind == "bind" and not def.manual and section.db[def.key]
            if key and (not def.needs or ns.Settings(def.needs).enabled) then
                for _, modifier in ipairs(def.anyModifier and ns.MODIFIERS or { "" }) do
                    keys[modifier .. key] = { def.click, def.button or "LeftButton" }
                end
            end
        end
    end
    if claim then
        local map = {}
        for key, to in pairs(keys) do map[key] = "CLICK " .. to[1] .. ":" .. to[2] end
        claim.replace(map)
        claim.commit()
    else
        ClearOverrideBindings(owner)
        for key, to in pairs(keys) do SetOverrideBindingClick(owner, true, key, to[1], to[2]) end
    end
end

-- Several changes in one frame bind once.
local scheduled = false
local function Schedule()
    if scheduled then return end
    scheduled = true
    C_Timer.After(0, function()
        scheduled = false
        ns.AfterCombat(Apply)
    end)
end

-- Controller Forever's binds are ready by login.
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    for _, section in ipairs(ns.sections) do
        for _, def in ipairs(section.options) do
            if def.kind == "bind" then ns.Watch(section.key, def.key, Schedule) end
        end
    end
end)

-- A key's name as the game shows it ("Shift-F", a pad button's glyph name).
function ns.KeyText(key)
    if not key then return "Not bound" end
    if GetBindingText then
        local ok, text = pcall(GetBindingText, key)
        if ok and text and text ~= "" then return text end
    end
    return key
end
