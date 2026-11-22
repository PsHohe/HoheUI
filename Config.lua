-- Settings: what each part of HoheUI can be told, saved in HoheUIDB, and the
-- /hoheui command.
--
-- Every part adds its options to a page here, and the settings window
-- (Options.lua) draws the pages from that list, so a new option is only
-- written where it's used:
--
--   local db = ns.AddOptions("party", {
--       { key = "hots", kind = "toggle", label = "Your HoTs", default = true },
--   })
--   ns.Watch("party", "hots", function(on) ... end)
--
-- db.hots is the saved value, or the default. A watcher runs once when the
-- saved settings load (they load after the files run), then on every change.
-- An option marked `reload` takes effect on the next /reload, so its watchers
-- only run at load.
--
-- Kinds: "toggle"; "range" (min, max, step; percent = true shows 0.5 as 50%);
-- "bind" (see Binds.lua); "button" (text, run); "choice" (choices, a list of
-- { value, text }); "header". `hint` is a line of
-- small print under the label. A page with an "enabled" toggle greys out its
-- other options while that's off.
--
-- Only values that differ from the default are saved, so a changed default
-- reaches everyone who never touched that option.
local addonName, ns = ...

ns.sections = {}
ns.modules = {}
local byKey = {}
local modulesByTitle = {}
local watchers = {}
local loaded = false
local atLoad = {} -- each reload option's value as it was loaded

-- Pages, in the order the window lists them. Pages given the same module
-- share one entry in the window's list, with a tab each across the top; a
-- page without one is a module of its own.
function ns.AddSection(key, title, moduleTitle)
    local section = { key = key, title = title, options = {}, defaults = {}, defs = {} }
    local module = moduleTitle and modulesByTitle[moduleTitle]
    if not module then
        module = { key = key, title = moduleTitle or title, sections = {} }
        ns.modules[#ns.modules + 1] = module
        if moduleTitle then modulesByTitle[moduleTitle] = module end
    end
    module.sections[#module.sections + 1] = section
    section.module = module
    section.db = setmetatable({}, {
        __index = function(_, name)
            local saved = ns.db and ns.db[key]
            local value = saved and saved[name]
            if value == nil then value = section.defaults[name] end
            return value
        end,
        __newindex = function() error("HoheUI: change settings with ns.Set") end,
    })
    ns.sections[#ns.sections + 1] = section
    byKey[key] = section
end

ns.AddSection("player", "Player", "Unit Frames")
ns.AddSection("target", "Target", "Unit Frames")
ns.AddSection("pet", "Pet", "Unit Frames")
ns.AddSection("party", "Party", "Unit Frames")
ns.AddSection("raid", "Raid", "Unit Frames")
ns.AddSection("cooldowns", "Cooldowns")
ns.AddSection("chat", "Chat")
ns.AddSection("dictation", "Dictation")
ns.AddSection("notch", "Notch")
ns.AddSection("minimap", "Minimap")
ns.AddSection("loot", "Loot")
ns.AddSection("delete", "Deleting")
ns.AddSection("keys", "Extra Keys")
ns.AddSection("binds", "Keybinds")

-- A page's settings, read-only: db.name.
function ns.Settings(sectionKey)
    return byKey[sectionKey].db
end

function ns.GetSection(sectionKey)
    return byKey[sectionKey]
end

-- Adds options to the end of a page and returns its settings.
function ns.AddOptions(sectionKey, options)
    local section = byKey[sectionKey]
    for _, def in ipairs(options) do
        section.options[#section.options + 1] = def
        if def.key then
            section.defaults[def.key] = def.default
            section.defs[def.key] = def
        end
    end
    return section.db
end

local function Notify(sectionKey, name)
    local list = watchers[sectionKey .. "." .. name]
    if not list then return end
    local value = byKey[sectionKey].db[name]
    for _, fn in ipairs(list) do fn(value) end
end

-- fn(value) now if the settings have loaded, else when they do; then after
-- every change.
function ns.Watch(sectionKey, name, fn)
    local id = sectionKey .. "." .. name
    watchers[id] = watchers[id] or {}
    table.insert(watchers[id], fn)
    if loaded then fn(byKey[sectionKey].db[name]) end
end

function ns.Set(sectionKey, name, value)
    if not loaded then return end
    local section = byKey[sectionKey]
    if value == section.defaults[name] then value = nil end
    local saved = ns.db[sectionKey] or {}
    saved[name] = value
    ns.db[sectionKey] = next(saved) and saved or nil
    local def = section.defs[name]
    if def and def.reload then return end
    Notify(sectionKey, name)
end

function ns.ResetSection(sectionKey)
    for _, def in ipairs(byKey[sectionKey].options) do
        if def.key then ns.Set(sectionKey, def.key, def.default) end
    end
end

-- Whether a reload option has changed since the settings loaded.
function ns.NeedsReload()
    for id, value in pairs(atLoad) do
        local sectionKey, name = strsplit(".", id)
        if byKey[sectionKey].db[name] ~= value then return true end
    end
    return false
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, _, name)
    if name ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")
    if type(HoheUIDB) ~= "table" then HoheUIDB = {} end
    HoheUIDB.version = 1
    ns.db = HoheUIDB
    loaded = true
    for _, section in ipairs(ns.sections) do
        for _, def in ipairs(section.options) do
            if def.key then
                if def.reload then atLoad[section.key .. "." .. def.key] = section.db[def.key] end
                Notify(section.key, def.key)
            end
        end
    end
end)

-- /hoheui -------------------------------------------------------------------------
-- On its own it opens the settings; parts add their own words after it.

local commands = {}

function ns.AddCommand(name, help, run)
    commands[#commands + 1] = { name = name, help = help, run = run }
end

SLASH_HOHEUI1 = "/hoheui"
SlashCmdList.HOHEUI = function(msg)
    local name, rest = strmatch(strtrim(msg or ""), "^(%S*)%s*(.-)$")
    name = name:lower()
    if name == "" and ns.ToggleOptions then
        ns.ToggleOptions()
        return
    end
    for _, command in ipairs(commands) do
        if command.name == name then
            command.run(rest)
            return
        end
    end
    print("HoheUI: /hoheui - open the settings")
    for _, command in ipairs(commands) do
        print("HoheUI: /hoheui " .. command.name .. " - " .. command.help)
    end
end
