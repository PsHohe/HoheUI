-- Dictation: DictApp (the Mac dictation app) types into a draft panel here,
-- where you check the text, pick the channel and send it. A small pill near
-- the top of the screen shows when DictApp is listening or working.
--
-- Addons can't talk to other programs, so DictApp only presses keys. These
-- override bindings give them a meaning; they sit on top of your own key
-- bindings and are never saved with them:
--
--   Ctrl+Shift+F11          open the draft and focus it, for DictApp to paste into
--   Ctrl+Shift+F10          listening (plain dictation)
--   Ctrl+Shift+F1-F4        listening with AI agent 1-4
--   Alt+Ctrl+Shift+F1-F4    listening with AI agent 5-8
--   Ctrl+Shift+F12          working (transcribing, AI cleanup)
--   Ctrl+Shift+F5           done: the text is in the draft
--   Alt+Ctrl+Shift+F12      stopped: cancelled or failed
--
-- F6-F9 are left alone: Steam Input sends the controller's back buttons as
-- those, and the extra keys and Controller Forever use them.
--
-- The draft is HoheUI's own line, like the chat bubbles' reply line: opening
-- the chat window from an addon taints it. Enter (or A) sends, Tab (or the
-- D-pad) changes the channel, Escape (or B) drops it. The channel you pick is
-- remembered, and whispers you get or send are offered as channels. Long text
-- goes out as several messages of at most 255 bytes.
--
-- While a chat input has focus it takes every key and bindings don't fire, so
-- this also listens on the chat inputs for the same chords. It only listens:
-- it never changes what's typed there. On a Mac a function key also types a
-- private-use character; the draft drops those.
--
-- DictApp writes its agents' names and colours into DictApp.lua in this
-- folder; the game reads that on /reload. /hoheui dictation checks the keys.
local addonName, ns = ...

local C = ns.COLORS
local IsSecret = ns.IsSecret

local HEIGHT = 30
local PAD = 12
local STRIP = 3
local BARS, BAR_W, BAR_GAP, BAR_MAX = 5, 3, 2, 14
local WAVE_WIDTH = BARS * BAR_W + (BARS - 1) * BAR_GAP
local TEXT_GAP = 8
local TAG_GAP = 6
local LISTEN_TIMEOUT, WORK_TIMEOUT = 300, 60 -- a lost key can't leave the pill up
local DONE_HOLD, STOPPED_HOLD, FADE = 1.2, 1.8, 0.3
local REPEAT = 0.3 -- one chord can reach both a binding and a chat input

local DRAFT_WIDTH = 560
local DRAFT_TEXT = 14
local MAX_BYTES = 255 -- the game's limit for one chat message
local MAX_RECENT = 5
local HINT = "Enter or A: send    Tab or D-pad: channel    Esc or B: drop"

local BUTTON = "HoheUIDictation"
local SIGNALS = {
    ["CTRL-SHIFT-F11"] = "compose",
    ["CTRL-SHIFT-F10"] = "listen",
    ["CTRL-SHIFT-F12"] = "working",
    ["CTRL-SHIFT-F5"] = "done",
    ["ALT-CTRL-SHIFT-F12"] = "stopped",
}
for i = 1, 4 do
    SIGNALS["CTRL-SHIFT-F" .. i] = "agent" .. i
    SIGNALS["ALT-CTRL-SHIFT-F" .. i] = "agent" .. (i + 4)
end

local db = ns.AddOptions("dictation", {
    { key = "enabled", kind = "toggle", label = "DictApp", default = true,
      hint = "DictApp types into a draft here, and the pill shows when it's listening or working." },
    { key = "y", kind = "range", label = "Pill up / down", default = 400, min = -520, max = 520, step = 10,
      hint = "Where the pill's top sits, from the middle of the screen." },
    { key = "draftY", kind = "range", label = "Draft up / down", default = -150, min = -520, max = 520, step = 10,
      hint = "Where the draft's top sits, from the middle of the screen." },
    { key = "preview", kind = "button", label = "Preview", text = "Show a dictation",
      run = function() ns.PreviewDictation() end },
})
-- Also saved here, without a row of their own: "channel", the last channel
-- picked ("SAY", "PARTY", "WHISPER:Name-Realm"...), and "recent", the newest
-- whisper partners first.

-- The pill ---------------------------------------------------------------------------

local pill = CreateFrame("Frame", "HoheUIDictationPill", ns.root)
pill:SetFrameStrata("HIGH")
pill:SetHeight(HEIGHT)
pill:Hide()
ns.CreatePanel(pill)

local strip = pill:CreateTexture(nil, "ARTWORK")
strip:SetPoint("TOPLEFT")
strip:SetPoint("BOTTOMLEFT")
strip:SetWidth(STRIP)

local bars = {}
for i = 1, BARS do
    local bar = pill:CreateTexture(nil, "ARTWORK")
    bar:SetSize(BAR_W, 2)
    bar:SetPoint("LEFT", pill, "LEFT", STRIP + PAD + (i - 1) * (BAR_W + BAR_GAP), 0)
    bars[i] = bar
end

local label = ns.CreateText(pill, 13)
label:SetPoint("LEFT", pill, "LEFT", STRIP + PAD + WAVE_WIDTH + TEXT_GAP, 0)
local tag = ns.CreateText(pill, 13)
tag:SetPoint("LEFT", label, "RIGHT", TAG_GAP, 0)

local state, since, fadeAt, phase = nil, 0, nil, 0
local agentName, agentColor = nil, C.accent

-- An agent's name and colour, as DictApp last wrote them into DictApp.lua.
local function AgentInfo(index)
    local list = type(HoheUIDictAppAgents) == "table" and HoheUIDictAppAgents or nil
    local agent = list and list[index]
    local color = agent and type(agent.color) == "table" and agent.color or C.accent
    return agent and agent.name or ("Agent " .. index), color
end

local function ShowPill(newState, text, stripColor)
    state, since, fadeAt = newState, GetTime(), nil
    strip:SetColorTexture(stripColor[1], stripColor[2], stripColor[3], 1)
    for _, bar in ipairs(bars) do
        bar:SetColorTexture(stripColor[1], stripColor[2], stripColor[3], 1)
        bar:SetHeight(4)
    end
    label:SetText(text)
    tag:SetText(agentName or "")
    tag:SetTextColor(agentColor[1], agentColor[2], agentColor[3])
    local width = STRIP + PAD + WAVE_WIDTH + TEXT_GAP + label:GetStringWidth() + PAD
    if agentName then width = width + TAG_GAP + tag:GetStringWidth() end
    pill:SetWidth(width)
    pill:SetAlpha(1)
    pill:Show()
end

-- Drawn, not measured: no audio reaches the game.
pill:SetScript("OnUpdate", function(self, elapsed)
    local now = GetTime()
    if state == "listen" then
        phase = phase + elapsed * 8
        for i, bar in ipairs(bars) do
            local level = math.abs(math.sin(phase + i * 1.7) * math.sin(phase * 0.37 + i))
            bar:SetHeight(math.max(2, BAR_MAX * (0.2 + 0.8 * level)))
        end
        if not fadeAt and now - since > LISTEN_TIMEOUT then fadeAt = now end
    elseif state == "working" then
        phase = phase + elapsed * 5
        for i, bar in ipairs(bars) do
            bar:SetHeight(BAR_MAX * (0.35 + 0.25 * math.sin(phase - i * 0.9)))
        end
        if not fadeAt and now - since > WORK_TIMEOUT then fadeAt = now end
    end
    if fadeAt and now > fadeAt then
        local alpha = 1 - (now - fadeAt) / FADE
        if alpha <= 0 then
            state = nil
            self:Hide()
        else
            self:SetAlpha(alpha)
        end
    end
end)

-- Channels ---------------------------------------------------------------------------

local function Recent()
    return type(db.recent) == "table" and db.recent or {}
end

-- A whisper partner goes to the front of the list. Secret names can't be kept.
local function AddRecent(name)
    if not name or IsSecret(name) or name == "" then return end
    local list = { name }
    for _, other in ipairs(Recent()) do
        if other ~= name and #list < MAX_RECENT then list[#list + 1] = other end
    end
    ns.Set("dictation", "recent", list)
end

-- The channels you can send to right now, in a fixed order.
local function Channels()
    local list = { { id = "SAY", chatType = "SAY", label = "Say" } }
    if IsInGroup() then list[#list + 1] = { id = "PARTY", chatType = "PARTY", label = "Party" } end
    if IsInRaid() then list[#list + 1] = { id = "RAID", chatType = "RAID", label = "Raid" } end
    local instance = LE_PARTY_CATEGORY_INSTANCE
    if instance and IsInGroup(instance) then
        list[#list + 1] = { id = "INSTANCE_CHAT", chatType = "INSTANCE_CHAT", label = "Instance" }
    end
    if IsInGuild() then list[#list + 1] = { id = "GUILD", chatType = "GUILD", label = "Guild" } end
    for _, name in ipairs(Recent()) do
        local short = Ambiguate and Ambiguate(name, "none") or name
        list[#list + 1] = { id = "WHISPER:" .. name, chatType = "WHISPER", target = name, label = "To " .. short }
    end
    return list
end

local function TypeColor(chatType)
    local info = ChatTypeInfo and ChatTypeInfo[chatType]
    if info and info.r then return { info.r, info.g, info.b } end
    return C.text
end

-- In chat messaging lockdown only the game can send chat.
local function ChatLocked()
    return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
end

-- Words into messages of at most MAX_BYTES; a longer word is cut between characters.
local function Split(text)
    local parts, current = {}, ""
    for word in text:gmatch("%S+") do
        local candidate = current == "" and word or (current .. " " .. word)
        if #candidate <= MAX_BYTES then
            current = candidate
        else
            if current ~= "" then parts[#parts + 1] = current end
            while #word > MAX_BYTES do
                local cut = MAX_BYTES
                local nextByte = word:byte(cut + 1)
                while cut > 1 and nextByte and nextByte >= 128 and nextByte < 192 do
                    cut = cut - 1
                    nextByte = word:byte(cut + 1)
                end
                parts[#parts + 1] = word:sub(1, cut)
                word = word:sub(cut + 1)
            end
            current = word
        end
    end
    if current ~= "" then parts[#parts + 1] = current end
    return parts
end

-- The draft ----------------------------------------------------------------------------

local draft = CreateFrame("Frame", "HoheUIDictationDraft", ns.root)
draft:SetFrameStrata("DIALOG")
draft:SetWidth(DRAFT_WIDTH)
draft:EnableMouse(true)
draft:Hide()
ns.CreatePanel(draft)

draft.strip = draft:CreateTexture(nil, "ARTWORK")
draft.strip:SetPoint("TOPLEFT")
draft.strip:SetPoint("BOTTOMLEFT")
draft.strip:SetWidth(STRIP)

local LEFT = STRIP + PAD
local INPUT_WIDTH = DRAFT_WIDTH - LEFT - PAD

draft.channel = ns.CreateText(draft, 13)
draft.channel:SetPoint("TOPLEFT", LEFT, -PAD)
draft.hint = ns.CreateText(draft, 11, nil, C.muted)
draft.hint:SetPoint("BOTTOMLEFT", LEFT, PAD)
draft.hint:SetPoint("RIGHT", -PAD, 0)
draft.hint:SetJustifyH("LEFT")

local input = CreateFrame("EditBox", nil, draft)
input:SetMultiLine(true)
input:SetAutoFocus(false)
input:SetFont(ns.FONT_TEXT, DRAFT_TEXT, "")
input:SetMaxLetters(2000)
input:SetWidth(INPUT_WIDTH)
input:SetPoint("TOPLEFT", draft.channel, "BOTTOMLEFT", 0, -6)
input:SetTextColor(C.text[1], C.text[2], C.text[3])

-- The draft grows with its text; a hidden copy of the text measures it.
local measure = draft:CreateFontString(nil, "OVERLAY")
measure:SetFont(ns.FONT_TEXT, DRAFT_TEXT, "")
measure:SetWidth(INPUT_WIDTH)
measure:SetWordWrap(true)
measure:SetAlpha(0)
measure:SetPoint("TOPLEFT", input)

local function Layout()
    local text = input:GetText() or ""
    measure:SetText(text ~= "" and text or " ")
    local height = math.max(DRAFT_TEXT + 4, measure:GetStringHeight() + 4)
    input:SetHeight(height)
    draft:SetHeight(PAD + 16 + 6 + height + 8 + 14 + PAD)
end

local channels, current = {}, 1

local function ShowChannel()
    local channel = channels[current]
    local color = TypeColor(channel.chatType)
    draft.strip:SetColorTexture(color[1], color[2], color[3], 1)
    draft.channel:SetTextColor(color[1], color[2], color[3])
    local count = #channels > 1 and format("   |cff98a2ae%d/%d|r", current, #channels) or ""
    draft.channel:SetText(channel.label .. count)
end

local function Step(delta)
    if #channels < 2 then return end
    current = (current - 1 + delta) % #channels + 1
    ns.Set("dictation", "channel", channels[current].id)
    ShowChannel()
end

local function CloseDraft()
    draft:Hide()
    input:SetText("")
    input:ClearFocus()
end

local function SendDraft()
    if not draft:IsShown() then return end
    local text = strtrim(input:GetText() or "")
    if text == "" then
        CloseDraft()
        return
    end
    if ChatLocked() then
        draft.hint:SetText("|cffff6060The game blocks addon chat in this fight. Send it after, or Esc to drop it.|r")
        return
    end
    local channel = channels[current]
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    for _, part in ipairs(Split(text)) do
        send(part, channel.chatType, nil, channel.target)
    end
    CloseDraft()
end

local function OpenDraft()
    if not draft:IsShown() then
        channels = Channels()
        current = 1
        for i, channel in ipairs(channels) do
            if channel.id == db.channel then current = i end
        end
        ShowChannel()
    end
    -- New dictation adds to what's there, a space apart.
    local text = input:GetText() or ""
    if strtrim(text) == "" then
        input:SetText("")
    elseif not text:find("%s$") then
        input:SetText(text .. " ")
    end
    draft.hint:SetText(HINT)
    draft:ClearAllPoints()
    draft:SetPoint("TOP", ns.root, "CENTER", 0, db.draftY)
    draft:Show()
    input:SetFocus()
    input:SetCursorPosition(#(input:GetText() or ""))
    Layout()
end

-- Function keys' private-use characters (U+F700-U+F8FF) and line breaks go:
-- a chat message is one line. Enter may arrive as a line break here.
local function Clean(text)
    return (text:gsub("\239[\156-\163][\128-\191]", ""):gsub("[\r\n]+", " "))
end

input:SetScript("OnTextChanged", function(self, userInput)
    local text = self:GetText() or ""
    local enter = userInput and text:find("[\r\n]")
    local cleaned = Clean(text)
    if cleaned ~= text then
        local cursor = self:GetCursorPosition()
        self:SetText(cleaned)
        self:SetCursorPosition(math.min(cursor, #cleaned))
    end
    Layout()
    if enter then SendDraft() end
end)
input:SetScript("OnEnterPressed", SendDraft)
input:SetScript("OnEscapePressed", CloseDraft)
input:SetScript("OnTabPressed", function() Step(IsShiftKeyDown() and -1 or 1) end)
draft:SetScript("OnMouseDown", function() input:SetFocus() end)

-- The controller, while the draft is open.
if draft.EnableGamePadButton then
    draft:EnableGamePadButton(true)
    draft:SetScript("OnGamePadButtonDown", function(_, button)
        if button == "PAD1" then
            SendDraft()
        elseif button == "PAD2" then
            CloseDraft()
        elseif button == "PADDLEFT" or button == "PADDUP" then
            Step(-1)
        elseif button == "PADDRIGHT" or button == "PADDDOWN" then
            Step(1)
        end
    end)
end

-- Signals ------------------------------------------------------------------------------

local lastSignal, lastAt = nil, 0

local function Signal(signal)
    if not db.enabled then return end
    local now = GetTime()
    if signal == lastSignal and now - lastAt < REPEAT then return end
    lastSignal, lastAt = signal, now
    local digit = signal:match("^agent(%d)$")
    local index = digit and tonumber(digit)
    local active = state == "listen" or state == "working"
    if signal == "listen" or index then
        if index then
            agentName, agentColor = AgentInfo(index)
        else
            agentName, agentColor = nil, C.accent
        end
        ShowPill("listen", "Listening", agentColor)
    elseif signal == "working" then
        ShowPill("working", "Working", agentColor)
    elseif signal == "compose" then
        OpenDraft()
    elseif signal == "done" and active then
        ShowPill("done", "Done", C.friendly)
        fadeAt = now + DONE_HOLD
    elseif signal == "stopped" and active then
        ShowPill("stopped", "Stopped", C.hostile)
        fadeAt = now + STOPPED_HOLD
    end
end

-- Like the game's own key-to-button bindings: a button nobody sees, clicked as
-- the key goes down, with the signal as the mouse button.
local button = CreateFrame("Button", BUTTON, UIParent)
button:RegisterForClicks("AnyDown")
button:SetScript("OnClick", function(_, signal) Signal(signal) end)

local owner = CreateFrame("Frame")

local function Bind()
    ClearOverrideBindings(owner)
    if not db.enabled then return end
    for key, signal in pairs(SIGNALS) do
        SetOverrideBindingClick(owner, true, key, BUTTON, signal)
    end
end

-- Inputs with focus --------------------------------------------------------------------
-- Modifiers as the input saw them go down: DictApp presses a whole chord at
-- once, so by the time the key arrives the live state may read as released.

local MODIFIER_KEYS = { LCTRL = "ctrl", RCTRL = "ctrl", LSHIFT = "shift", RSHIFT = "shift", LALT = "alt", RALT = "alt" }
local held = { ctrl = false, shift = false, alt = false }

local function OnInputKeyDown(_, key)
    local modifier = MODIFIER_KEYS[key]
    if modifier then
        held[modifier] = true
        return
    end
    if not (held.ctrl or IsControlKeyDown()) or not (held.shift or IsShiftKeyDown()) then return end
    local alt = held.alt or IsAltKeyDown()
    local signal = SIGNALS[(alt and "ALT-" or "") .. "CTRL-SHIFT-" .. key]
    if signal then Signal(signal) end
end

local function OnInputKeyUp(_, key)
    local modifier = MODIFIER_KEYS[key]
    if modifier then held[modifier] = false end
end

local function OnInputFocusLost()
    -- Releases that happen elsewhere never reach the input.
    held.ctrl, held.shift, held.alt = false, false, false
end

local function ListenOn(box)
    if not box or box.hoheDictation then return end
    box.hoheDictation = true
    box:HookScript("OnKeyDown", OnInputKeyDown)
    box:HookScript("OnKeyUp", OnInputKeyUp)
    box:HookScript("OnEditFocusLost", OnInputFocusLost)
end

ListenOn(input)

-- Events -------------------------------------------------------------------------------

local handlers = {}

function handlers.PLAYER_LOGIN()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do ListenOn(_G["ChatFrame" .. i .. "EditBox"]) end
    ns.AfterCombat(Bind)
end

function handlers.CHAT_MSG_WHISPER(_, sender)
    AddRecent(sender)
end

function handlers.CHAT_MSG_WHISPER_INFORM(_, target)
    AddRecent(target)
end

local events = CreateFrame("Frame")
for event in pairs(handlers) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)

ns.Watch("dictation", "enabled", function()
    if IsLoggedIn() then ns.AfterCombat(Bind) end
    if not db.enabled then
        state = nil
        pill:Hide()
        CloseDraft()
    end
end)
ns.Watch("dictation", "y", function()
    pill:ClearAllPoints()
    pill:SetPoint("TOP", ns.root, "CENTER", 0, db.y)
end)

-- Preview and probe --------------------------------------------------------------------

function ns.PreviewDictation()
    Signal("agent1")
    C_Timer.After(2.5, function() if state == "listen" then Signal("working") end end)
    C_Timer.After(4, function()
        if state ~= "working" then return end
        Signal("compose")
        input:Insert("This is what a dictated message looks like before you send it.")
        Signal("done")
    end)
end

local function Probe()
    if not db.enabled then
        print("HoheUI: DictApp keys are off (Dictation page).")
        return
    end
    local taken = 0
    for key, signal in pairs(SIGNALS) do
        local action = GetBindingAction(key, true)
        if action ~= "CLICK " .. BUTTON .. ":" .. signal then
            taken = taken + 1
            print("HoheUI: " .. key .. " is taken by " .. ((action and action ~= "") and action or "nothing"))
        end
    end
    local list = type(HoheUIDictAppAgents) == "table" and HoheUIDictAppAgents or {}
    print(format("HoheUI: DictApp keys %s. %d agent names from DictApp, %d recent whispers.",
        taken == 0 and "ready" or "not ready, see above (leave combat or /reload)", #list, #Recent()))
end

ns.AddCommand("dictation", "check the DictApp keys", Probe)
