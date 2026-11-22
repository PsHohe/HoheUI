-- Chat bubbles: group chat and whispers float on screen as rounded cards, on
-- top of the chat window (which stays as it is).
--
-- Party chat pops out beside the member's tile in the party column, its tail
-- pointing at them. Raid chat (and party chat in a raid) stacks over the raid
-- grid with a class icon and the speaker's name, since it can't sit by their
-- tile. Whispers stack near the top left of the screen. In a stack the newest
-- card sits nearest its anchor and pushes the older ones along.
--
-- Clicking a card opens a reply line under it, already on that card's channel
-- (or whispering its sender); Enter sends, Escape closes. It's HoheUI's own
-- line, not the chat window's: opening that one from an addon taints it, and
-- then the game blocks what's typed there. Right-click dismisses a card, and
-- a card stays while the mouse is on it.
--
-- In chat messaging lockdown the game hands chat events over as secret
-- values: the text and name can still be shown, but not read, measured or
-- matched to a tile. Those cards go to the stack at full width, with no icon.
-- /hoheui chat previews them.
local _, ns = ...

local C = ns.COLORS
local IsSecret = ns.IsSecret

local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local RADIUS = 8
local STRIP_X, STRIP_WIDTH = 8, 3 -- the coloured bar down the left
local CONTENT_LEFT = 19
local PAD_RIGHT, PAD_TOP, PAD_BOTTOM = 12, 9, 10
local ICON = 16
local HEADER_GAP = 4 -- between the name line and the text
local TAG_GAP = 10 -- between the name and the channel tag
local LINE_SPACING = 2
local MAX_LINES = 5
local LOCKED_LINES = 3 -- the height a secret message gets, since it can't be measured
local MIN_TEXT_WIDTH = 24
local TAIL = 6 -- how far the tail reaches past the edge
local TILE_GAP = 4 -- between the tail's tip and the tile
local ANCHOR_GAP = 12 -- between a stack and what it hangs from
local STACK_GAP = 6
local SLIDE_SPEED = 14
local EXTRA_TIME = 6 -- the most a long message adds to the time on screen
local LINGER = 2 -- after the mouse leaves a card
local REPLY_HEIGHT = 32
local REPLY_MIN_WIDTH = 240
local REPLY_GAP = 6

local db = ns.AddOptions("chat", {
    { key = "enabled", kind = "toggle", label = "Chat bubbles", default = true,
      hint = "Group chat and whispers float on screen. The chat window stays as it is." },
    { key = "scale", kind = "range", label = "Size", default = 1, min = 0.5, max = 2, step = 0.05, percent = true },
    { key = "textSize", kind = "range", label = "Text size", default = 14, min = 10, max = 24, step = 1 },
    { key = "width", kind = "range", label = "Widest bubble", default = 280, min = 160, max = 520, step = 10 },
    { key = "duration", kind = "range", label = "Seconds on screen", default = 6, min = 2, max = 20, step = 1,
      hint = "Long messages stay a little longer." },
    { key = "opacity", kind = "range", label = "Background", default = 0.92, min = 0.4, max = 1, step = 0.02, percent = true },
    { key = "self", kind = "toggle", label = "Your own messages", default = true },
    { key = "preview", kind = "button", label = "Preview", text = "Show samples",
      hint = "Party samples go on the party tiles shown, so preview those first.",
      run = function() ns.PreviewChat() end },
    { kind = "header", label = "Party" },
    { key = "party", kind = "toggle", label = "Party chat", default = true, hint = "Beside the member's tile." },
    { key = "partySide", kind = "choice", label = "Side of the tile", default = "left",
      choices = { { value = "left", text = "Left" }, { value = "right", text = "Right" } } },
    { kind = "header", label = "Raid" },
    { key = "raid", kind = "toggle", label = "Raid chat", default = true,
      hint = "Over the raid frames, with who said it. Raid warnings too." },
    { key = "raidSide", kind = "choice", label = "Position", default = "above",
      choices = { { value = "above", text = "Above" }, { value = "below", text = "Below" } } },
    { key = "raidMax", kind = "range", label = "Most at once", default = 4, min = 1, max = 8, step = 1 },
    { kind = "header", label = "Whispers" },
    { key = "whisper", kind = "toggle", label = "Whispers", default = true, hint = "Battle.net whispers too." },
    { key = "whisperX", kind = "range", label = "Left / right", default = -480, min = -940, max = 940, step = 10,
      hint = "Where the top left corner sits, from the middle of the screen." },
    { key = "whisperY", kind = "range", label = "Up / down", default = 300, min = -520, max = 520, step = 10 },
    { key = "whisperMax", kind = "range", label = "Most at once", default = 3, min = 1, max = 6, step = 1 },
})

-- Channel tags, and the chat colour each card's bar takes.
local TAGS = {
    PARTY = "Party", PARTY_LEADER = "Party leader",
    INSTANCE_CHAT = "Instance", INSTANCE_CHAT_LEADER = "Instance leader",
    RAID = "Raid", RAID_LEADER = "Raid leader", RAID_WARNING = "Raid warning",
    WHISPER = "Whisper", BN_WHISPER = "Battle.net",
}
local PARTY_TYPES = { PARTY = true, PARTY_LEADER = true, INSTANCE_CHAT = true, INSTANCE_CHAT_LEADER = true }
-- Where a reply goes; a warning is answered in raid chat. Whispers go back to
-- the sender.
local REPLY_TYPES = {
    PARTY = "PARTY", PARTY_LEADER = "PARTY",
    INSTANCE_CHAT = "INSTANCE_CHAT", INSTANCE_CHAT_LEADER = "INSTANCE_CHAT",
    RAID = "RAID", RAID_LEADER = "RAID", RAID_WARNING = "RAID",
    WHISPER = "WHISPER", BN_WHISPER = "BN_WHISPER",
}
local REPLY_LABELS = { PARTY = "Party", INSTANCE_CHAT = "Instance", RAID = "Raid" }

local function TypeColor(chatType)
    local info = ChatTypeInfo and ChatTypeInfo[chatType]
    if info and info.r then return { info.r, info.g, info.b } end
    return C.accent
end

-- Whether every value can be read; secret ones can only be handed to widgets.
local function Readable(...)
    if canaccessvalue then return canaccessvalue(...) end
    for i = 1, select("#", ...) do
        if IsSecret((select(i, ...))) then return false end
    end
    return true
end

-- A measurement, or nil when the game made it secret. A pooled card that once
-- held secret text keeps answering with secret sizes, even for plain text.
local function Measured(value)
    if value == nil or IsSecret(value) then return nil end
    return value
end

local function StringWidth(fs)
    if fs.GetUnboundedStringWidth then return Measured(fs:GetUnboundedStringWidth()) end
    return Measured(fs:GetStringWidth())
end

-- Modern class icons where the client has them, else the old circles.
local function SetClassIcon(icon, class)
    if not class then return false end
    local atlas = "classicon-" .. class:lower()
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        icon:SetAtlas(atlas)
        return true
    end
    local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if not coords then return false end
    icon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
    icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    return true
end

-- The shape ------------------------------------------------------------------------
-- A rounded rectangle `out` units larger than `frame` on every side, from a
-- middle band, a top and bottom band between the corners, and a quarter
-- circle in each corner. The pieces don't overlap, so it can be translucent.

local function RoundedRect(frame, sublevel, out)
    local parts = {}
    local function Part()
        local tex = frame:CreateTexture(nil, "BACKGROUND", nil, sublevel)
        tex:SetTexture(ns.TEXTURE)
        parts[#parts + 1] = tex
        return tex
    end
    local r = RADIUS + out
    local middle = Part()
    middle:SetPoint("TOPLEFT", frame, "TOPLEFT", -out, out - r)
    middle:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", out, r - out)
    local top = Part()
    top:SetPoint("TOPLEFT", frame, "TOPLEFT", r - out, out)
    top:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", out - r, out - r)
    local bottom = Part()
    bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", r - out, -out)
    bottom:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", out - r, r - out)
    for _, corner in ipairs({ { "TOPLEFT", -1, 1 }, { "TOPRIGHT", 1, 1 }, { "BOTTOMLEFT", -1, -1 }, { "BOTTOMRIGHT", 1, -1 } }) do
        local point, x, y = corner[1], corner[2] * out, corner[3] * out
        local tex = Part()
        tex:SetSize(r, r)
        tex:SetPoint(point, frame, point, x, y)
        -- A circle twice the corner's size, so the corner shows one quarter.
        local mask = frame:CreateMaskTexture()
        mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetSize(r * 2, r * 2)
        mask:SetPoint(point, frame, point, x, y)
        tex:AddMaskTexture(mask)
    end
    return parts
end

local function Paint(parts, r, g, b, a)
    for _, tex in ipairs(parts) do tex:SetVertexColor(r, g, b, a) end
end

-- The tail: a triangle of one-unit columns, each a little shorter than the
-- last, with a black edge around it like the card's.
local function CreateTail(bubble)
    local tail = { edges = {}, fills = {} }
    for i = 0, TAIL do
        local half = TAIL - i
        local edge = bubble:CreateTexture(nil, "BACKGROUND", nil, -8)
        edge:SetTexture(ns.TEXTURE)
        edge:SetSize(1, half * 2 + 2)
        tail.edges[#tail.edges + 1] = { tex = edge, x = i }
        if half > 0 then
            local fill = bubble:CreateTexture(nil, "BACKGROUND", nil, -7)
            fill:SetTexture(ns.TEXTURE)
            fill:SetSize(1, half * 2)
            tail.fills[#tail.fills + 1] = { tex = fill, x = i }
        end
    end
    return tail
end

-- Points the tail out of the card's "RIGHT" or "LEFT" edge, or hides it (nil).
local function SetTail(bubble, edge)
    local point, dir = "LEFT", 1
    if edge == "LEFT" then point, dir = "RIGHT", -1 end
    for _, list in ipairs({ bubble.tail.edges, bubble.tail.fills }) do
        for _, column in ipairs(list) do
            column.tex:ClearAllPoints()
            column.tex:SetPoint(point, bubble, edge or "RIGHT", dir * column.x, 0)
            column.tex:SetShown(edge ~= nil)
        end
    end
end

local function PaintTail(bubble, alpha)
    for _, column in ipairs(bubble.tail.edges) do column.tex:SetVertexColor(0, 0, 0, alpha) end
    for _, column in ipairs(bubble.tail.fills) do
        column.tex:SetVertexColor(ns.PANEL[1], ns.PANEL[2], ns.PANEL[3], alpha)
    end
end

-- Cards ----------------------------------------------------------------------------
-- A card shows `bubble.data`: text, readable, color, reply (where an answer
-- goes, when the message could be read), and for a stack card a header
-- (name, class, tag). Cards are reused once they've faded out.

local bubbles = {}
local partyBubbles = {} -- by tile
local Release, Dismiss, OpenReply

-- Stops a card's countdown, as while the mouse is on it or it's being answered.
local function Hold(bubble)
    if bubble.timer then bubble.timer:Cancel() end
    bubble.timer = nil
end

local function Resume(bubble, seconds)
    Hold(bubble)
    bubble.timer = C_Timer.NewTimer(seconds, function() Dismiss(bubble) end)
end

local function Text(parent)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(ns.FONT_TEXT, 14, "")
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.6)
    fs:SetTextColor(C.text[1], C.text[2], C.text[3])
    fs:SetJustifyH("LEFT")
    return fs
end

local function CreateBubble()
    local bubble = CreateFrame("Frame", nil, ns.root)
    bubble:SetFrameStrata("MEDIUM")
    bubble:Hide()
    bubble.edge = RoundedRect(bubble, -8, 1)
    bubble.fill = RoundedRect(bubble, -7, 0)
    bubble.tail = CreateTail(bubble)
    SetTail(bubble, nil)
    bubble.highlight = RoundedRect(bubble, -6, 0)
    Paint(bubble.highlight, 1, 1, 1, 0)

    bubble:SetScript("OnEnter", function(self)
        if not self.active then return end
        Hold(self)
        Paint(self.highlight, 1, 1, 1, 0.06)
    end)
    bubble:SetScript("OnLeave", function(self)
        Paint(self.highlight, 1, 1, 1, 0)
        if self.active and not self.replying then Resume(self, LINGER) end
    end)
    bubble:SetScript("OnMouseUp", function(self, button)
        if not self.active then return end
        if button == "RightButton" then
            Dismiss(self)
        else
            OpenReply(self)
        end
    end)

    bubble.strip = bubble:CreateTexture(nil, "ARTWORK")
    bubble.strip:SetWidth(STRIP_WIDTH)
    bubble.strip:SetPoint("TOPLEFT", STRIP_X, -PAD_TOP)
    bubble.strip:SetPoint("BOTTOMLEFT", STRIP_X, PAD_BOTTOM)

    bubble.icon = bubble:CreateTexture(nil, "ARTWORK")
    bubble.icon:SetSize(ICON, ICON)
    local mask = bubble:CreateMaskTexture()
    mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(bubble.icon)
    bubble.icon:AddMaskTexture(mask)
    bubble.name = Text(bubble)
    bubble.name:SetWordWrap(false)
    bubble.tag = Text(bubble)
    bubble.tag:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
    bubble.tag:SetJustifyH("RIGHT")
    bubble.text = Text(bubble)
    bubble.text:SetJustifyV("MIDDLE")
    bubble.text:SetWordWrap(true)
    bubble.text:SetMaxLines(MAX_LINES)
    bubble.text:SetSpacing(LINE_SPACING)

    -- In: fades in and pops out of its anchor, overshooting a touch.
    local intro = bubble:CreateAnimationGroup()
    intro:SetToFinalAlpha(true)
    local fadeIn = intro:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(0.15)
    local grow = intro:CreateAnimation("Scale")
    grow:SetScaleFrom(0.8, 0.8)
    grow:SetScaleTo(1.04, 1.04)
    grow:SetDuration(0.18)
    grow:SetSmoothing("OUT")
    local settle = intro:CreateAnimation("Scale")
    settle:SetScaleFrom(1, 1)
    settle:SetScaleTo(1 / 1.04, 1 / 1.04)
    settle:SetDuration(0.1)
    settle:SetStartDelay(0.18)
    settle:SetSmoothing("IN_OUT")

    -- Out: fades while shrinking a little, then the card is free again.
    local outro = bubble:CreateAnimationGroup()
    outro:SetToFinalAlpha(true)
    local fadeOut = outro:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(0.3)
    local shrink = outro:CreateAnimation("Scale")
    shrink:SetScaleFrom(1, 1)
    shrink:SetScaleTo(0.94, 0.94)
    shrink:SetDuration(0.3)
    shrink:SetSmoothing("IN")
    outro:SetScript("OnFinished", function() Release(bubble) end)

    bubble.intro, bubble.outro = intro, outro
    bubble.scales = { grow, settle, shrink }
    bubbles[#bubbles + 1] = bubble
    return bubble
end

local function Acquire()
    for _, bubble in ipairs(bubbles) do
        if not bubble:IsShown() then return bubble end
    end
    return CreateBubble()
end

-- Lays the card out for its data at the current settings.
local function Fill(bubble)
    local data = bubble.data
    local size, alpha = db.textSize, db.opacity
    bubble:SetScale(db.scale)
    Paint(bubble.edge, 0, 0, 0, alpha)
    Paint(bubble.fill, ns.PANEL[1], ns.PANEL[2], ns.PANEL[3], alpha)
    PaintTail(bubble, alpha)
    bubble.strip:SetColorTexture(data.color[1], data.color[2], data.color[3], 1)

    local maxWidth = db.width - CONTENT_LEFT - PAD_RIGHT
    local text = bubble.text
    text:SetFont(ns.FONT_TEXT, size, "")
    text:SetText(data.text)
    text:SetWidth(maxWidth)
    local width, height = maxWidth, LOCKED_LINES * (size + LINE_SPACING)
    -- Sized to the text when it can be measured, else the locked layout.
    local textWidth = data.readable and StringWidth(text)
    if textWidth then
        local fitted = math.max(MIN_TEXT_WIDTH, math.min(math.ceil(textWidth), maxWidth))
        text:SetWidth(fitted)
        local textHeight = Measured(text:GetStringHeight())
        if textHeight then
            width, height = fitted, math.ceil(textHeight)
        else
            text:SetWidth(maxWidth)
        end
    end
    text:SetHeight(height)

    local top = PAD_TOP
    bubble.name:SetShown(data.header)
    bubble.tag:SetShown(data.header)
    bubble.icon:SetShown(data.header and SetClassIcon(bubble.icon, data.class))
    if data.header then
        local nameSize = size - 1
        local lineHeight = math.max(ICON, nameSize)
        local middle = -top - lineHeight / 2
        local tagSize = math.max(size - 4, 9)
        bubble.name:SetFont(ns.FONT_TEXT, nameSize, "")
        bubble.tag:SetFont(ns.FONT_TEXT, tagSize, "")
        bubble.name:SetText(data.name)
        bubble.tag:SetText(data.tag:upper())
        local cc = data.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[data.class]
        local color = cc and { cc.r, cc.g, cc.b } or C.text
        bubble.name:SetTextColor(color[1], color[2], color[3])

        local nameX = CONTENT_LEFT + (bubble.icon:IsShown() and ICON + 6 or 0)
        bubble.icon:ClearAllPoints()
        bubble.icon:SetPoint("LEFT", bubble, "TOPLEFT", CONTENT_LEFT, middle)
        bubble.name:ClearAllPoints()
        bubble.name:SetPoint("LEFT", bubble, "TOPLEFT", nameX, middle)
        bubble.tag:ClearAllPoints()
        bubble.tag:SetPoint("RIGHT", bubble, "TOPRIGHT", -PAD_RIGHT, middle)
        local tagWidth = Measured(bubble.tag:GetStringWidth())
        -- Unmeasurable: a generous guess for the short capitalised tag.
        tagWidth = math.ceil(tagWidth or #data.tag * tagSize * 0.75)
        local indent = nameX - CONTENT_LEFT
        local nameWidth = data.readable and StringWidth(bubble.name)
        if nameWidth then
            local headerWidth = indent + math.ceil(nameWidth) + TAG_GAP + tagWidth
            width = math.max(width, math.min(headerWidth, maxWidth))
        elseif data.readable then
            width = maxWidth
        end
        bubble.name:SetWidth(math.max(1, width - indent - TAG_GAP - tagWidth))
        top = top + lineHeight + HEADER_GAP
    end

    text:ClearAllPoints()
    text:SetPoint("TOPLEFT", CONTENT_LEFT, -top)
    -- Kept, so nothing asks a card anchored near secret values for its size.
    bubble.width, bubble.height = CONTENT_LEFT + width + PAD_RIGHT, top + height + PAD_BOTTOM
    bubble:SetSize(bubble.width, bubble.height)
end

local function Duration(data)
    local extra = 0
    if data.readable then extra = math.min(EXTRA_TIME, math.max(0, (#data.text - 50) / 25)) end
    return db.duration + extra
end

-- Fills the card and plays it in, growing out of `origin`.
local function Present(bubble, data, origin)
    bubble.data = data
    Fill(bubble)
    for _, anim in ipairs(bubble.scales) do anim:SetOrigin(origin, 0, 0) end
    bubble.outro:Stop()
    bubble.intro:Stop()
    bubble:SetAlpha(1)
    bubble:Show()
    bubble.intro:Play()
    bubble.active = true
    bubble:EnableMouse(true)
    if not bubble.replying then Resume(bubble, Duration(data)) end
end

-- Stacks ---------------------------------------------------------------------------
-- A list of cards, newest first. Each card has an offset from the stack's
-- anchor and slides to its target when the cards before it change.

local slider = CreateFrame("Frame")

local function Slide(_, elapsed)
    local step = math.min(1, elapsed * SLIDE_SPEED)
    local moving = false
    for _, bubble in ipairs(bubbles) do
        local stack = bubble.stack
        if stack then
            local gap = bubble.target - bubble.offset
            if math.abs(gap) > 0.5 then
                bubble.offset = bubble.offset + gap * step
                moving = true
            else
                bubble.offset = bubble.target
            end
            stack.Place(bubble)
        end
    end
    if not moving then slider:SetScript("OnUpdate", nil) end
end

local function Layout(stack)
    local offset = 0
    for _, bubble in ipairs(stack.cards) do
        bubble.target = offset
        bubble.offset = bubble.offset or offset -- a new card starts in place
        stack.Place(bubble)
        offset = offset + bubble.height + STACK_GAP
    end
    slider:SetScript("OnUpdate", Slide)
end

local function Push(stack, data)
    local bubble = Acquire()
    bubble.stack, bubble.offset = stack, nil
    SetTail(bubble, nil)
    table.insert(stack.cards, 1, bubble)
    Present(bubble, data, stack.Origin())
    Layout(stack)
    while #stack.cards > stack.Max() do Dismiss(stack.cards[#stack.cards]) end
end

-- The raid stack hangs over (or under) the raid grid, or the party column
-- outside a raid, centred on it.
local banner = {
    cards = {},
    Max = function() return db.raidMax end,
    Origin = function() return db.raidSide == "below" and "TOP" or "BOTTOM" end,
    Place = function(bubble)
        local anchor = (IsInRaid() and ns.raidGrid) or ns.partyColumn
        bubble:ClearAllPoints()
        if db.raidSide == "below" then
            bubble:SetPoint("TOP", anchor, "BOTTOM", 0, -(ANCHOR_GAP + bubble.offset))
        else
            bubble:SetPoint("BOTTOM", anchor, "TOP", 0, ANCHOR_GAP + bubble.offset)
        end
    end,
}

-- Whispers hang from a point given from the middle of the screen, downwards.
local whispers = {
    cards = {},
    Max = function() return db.whisperMax end,
    Origin = function() return "LEFT" end,
    Place = function(bubble)
        local s = db.scale
        bubble:ClearAllPoints()
        bubble:SetPoint("TOPLEFT", ns.root, "CENTER", db.whisperX / s, db.whisperY / s - bubble.offset)
    end,
}

local CloseReply

function Dismiss(bubble)
    Hold(bubble)
    bubble.active = false
    bubble:EnableMouse(false)
    if bubble.replying then CloseReply() end
    Paint(bubble.highlight, 1, 1, 1, 0)
    local stack = bubble.stack
    if stack then
        for i, card in ipairs(stack.cards) do
            if card == bubble then
                table.remove(stack.cards, i)
                break
            end
        end
        bubble.stack = nil
        Layout(stack)
    end
    bubble.intro:Stop()
    bubble.outro:Play()
end

function Release(bubble)
    bubble:Hide()
    bubble.data = nil
    if bubble.tile then
        partyBubbles[bubble.tile] = nil
        bubble.tile = nil
    end
end

-- Reply -----------------------------------------------------------------------------
-- One line, opened under the card that was clicked, in the card's look.

local reply = CreateFrame("Frame", nil, ns.root)
reply:SetFrameStrata("DIALOG")
reply:SetHeight(REPLY_HEIGHT)
reply:SetClampedToScreen(true)
reply:EnableMouse(true)
reply:Hide()
reply.edge = RoundedRect(reply, -8, 1)
reply.fill = RoundedRect(reply, -7, 0)
reply.strip = reply:CreateTexture(nil, "ARTWORK")
reply.strip:SetWidth(STRIP_WIDTH)
reply.strip:SetPoint("TOPLEFT", STRIP_X, -8)
reply.strip:SetPoint("BOTTOMLEFT", STRIP_X, 8)
reply.label = Text(reply)
reply.label:SetPoint("LEFT", CONTENT_LEFT, 0)
reply.label:SetWordWrap(false)

local input = CreateFrame("EditBox", nil, reply)
input:SetAutoFocus(false)
input:SetFont(ns.FONT_TEXT, 14, "")
input:SetMaxLetters(255)
input:SetPoint("LEFT", reply.label, "RIGHT", 8, 0)
input:SetPoint("RIGHT", -PAD_RIGHT, 0)
input:SetHeight(REPLY_HEIGHT - 8)
input:SetTextColor(C.text[1], C.text[2], C.text[3])

function CloseReply()
    local bubble = reply.bubble
    reply.bubble = nil
    reply:Hide() -- first, so losing focus below doesn't close it again
    input:SetText("")
    input:ClearFocus()
    if bubble then
        bubble.replying = false
        if bubble.active and not bubble:IsMouseOver() then Resume(bubble, LINGER) end
    end
end

-- In chat messaging lockdown only the game can send chat.
local function ChatLocked()
    return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
end

local function Send(to, text)
    if to.chatType == "BN_WHISPER" then
        local send = (C_BattleNet and C_BattleNet.SendWhisper) or BNSendWhisper
        if send then send(to.target, text) end
        return
    end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    send(text, to.chatType, nil, to.target)
end

input:SetScript("OnEnterPressed", function(self)
    local text = strtrim(self:GetText() or "")
    local to = reply.bubble and reply.bubble.data and reply.bubble.data.reply
    if to and text ~= "" then
        if ChatLocked() then
            print("HoheUI: the game blocks addon chat here until the fight is over. Use the chat window.")
        else
            Send(to, text)
        end
    end
    CloseReply()
end)
input:SetScript("OnEscapePressed", CloseReply)
input:SetScript("OnEditFocusLost", function() if reply:IsShown() then CloseReply() end end)

function OpenReply(bubble)
    local to = bubble.data and bubble.data.reply
    if not to then
        print("HoheUI: the game kept this message secret, so it can't be answered from here.")
        return
    end
    if ChatLocked() then
        print("HoheUI: the game blocks addon chat here until the fight is over. Use the chat window.")
        return
    end
    if reply.bubble and reply.bubble ~= bubble then CloseReply() end
    reply.bubble = bubble
    bubble.replying = true
    Hold(bubble)

    local alpha = db.opacity
    Paint(reply.edge, 0, 0, 0, math.max(alpha, 0.95))
    Paint(reply.fill, ns.PANEL[1], ns.PANEL[2], ns.PANEL[3], math.max(alpha, 0.95))
    local color = bubble.data.color
    reply.strip:SetColorTexture(color[1], color[2], color[3], 1)
    reply.label:SetFont(ns.FONT_TEXT, db.textSize, "")
    reply.label:SetTextColor(color[1], color[2], color[3])
    reply.label:SetText("To " .. to.label)
    input:SetFont(ns.FONT_TEXT, db.textSize, "")
    reply:SetScale(db.scale)
    reply:SetWidth(math.max(bubble.width, REPLY_MIN_WIDTH))
    reply:ClearAllPoints()
    reply:SetPoint("TOPLEFT", bubble, "BOTTOMLEFT", 0, -REPLY_GAP)
    reply:Show()
    input:SetFocus()
end

-- Party ------------------------------------------------------------------------------

local function AnchorParty(bubble)
    local tile = bubble.tile
    bubble:ClearAllPoints()
    if db.partySide == "right" then
        bubble:SetPoint("LEFT", tile, "RIGHT", TAIL + TILE_GAP, 0)
        SetTail(bubble, "LEFT")
    else
        bubble:SetPoint("RIGHT", tile, "LEFT", -(TAIL + TILE_GAP), 0)
        SetTail(bubble, "RIGHT")
    end
end

-- A member's new message replaces the one beside their tile.
local function ShowAtTile(tile, data)
    local bubble = partyBubbles[tile]
    if not bubble then
        bubble = Acquire()
        bubble.tile = tile
        partyBubbles[tile] = bubble
    end
    AnchorParty(bubble)
    Present(bubble, data, db.partySide == "right" and "LEFT" or "RIGHT")
end

local function FindTile(guid)
    for _, tile in ipairs(ns.partyTiles or {}) do
        local unitGUID = tile:IsVisible() and UnitGUID(tile.unit)
        if unitGUID and not IsSecret(unitGUID) and unitGUID == guid then return tile end
    end
end

-- Messages ---------------------------------------------------------------------------

local function ClassOf(guid)
    if not (guid and GetPlayerInfoByGUID) or guid == "" then return nil end
    local _, class = GetPlayerInfoByGUID(guid)
    if class and not IsSecret(class) then return class end
end

local function BattleNetGUID(id)
    if not (C_BattleNet and C_BattleNet.GetAccountInfoByID) or not Readable(id) or not id then return nil end
    local info = C_BattleNet.GetAccountInfoByID(id)
    local game = info and info.gameAccountInfo
    return game and game.playerGuid
end

-- A card's data from a chat event's payload. Nothing is read from secret values.
local function Describe(chatType, text, sender, guid, bnSenderID, noIcons)
    local readable = Readable(text, sender, guid)
    if C_ChatInfo and C_ChatInfo.ReplaceIconAndGroupExpressions then
        text = C_ChatInfo.ReplaceIconAndGroupExpressions(text, noIcons, true)
    end
    local data = { text = text, readable = readable, color = TypeColor(chatType), tag = TAGS[chatType], header = true }
    data.name = sender
    if readable then
        -- A sender is "First Surname-Realm" on Forever. The name is shown
        -- without the realm and answered exactly as sent, as the chat window does.
        if chatType == "BN_WHISPER" then
            guid = BattleNetGUID(bnSenderID)
        elseif Ambiguate then
            data.name = Ambiguate(sender, chatType == "WHISPER" and "none" or "short")
        end
        data.class = ClassOf(guid)
        local to = REPLY_TYPES[chatType]
        if to == "WHISPER" or to == "BN_WHISPER" then
            local target = to == "BN_WHISPER" and bnSenderID or sender
            data.reply = { chatType = to, target = target, label = data.name }
        else
            data.reply = { chatType = to, label = REPLY_LABELS[to] }
        end
    end
    return data, readable and guid
end

local function OnGroupMessage(chatType, text, sender, ...)
    local guid, bnSenderID = select(10, ...)
    local noIcons = select(15, ...)
    local isParty = PARTY_TYPES[chatType]
    if not db[isParty and "party" or "raid"] then return end
    local data, readGUID = Describe(chatType, text, sender, guid, bnSenderID, noIcons)
    if readGUID and readGUID == UnitGUID("player") and not db.self then return end
    local tile = isParty and readGUID and not IsInRaid() and FindTile(readGUID)
    if tile then
        data.header = false
        ShowAtTile(tile, data)
    else
        Push(banner, data)
    end
end

local function OnWhisper(chatType, text, sender, ...)
    if not db.whisper then return end
    local guid, bnSenderID = select(10, ...)
    local noIcons = select(15, ...)
    Push(whispers, (Describe(chatType, text, sender, guid, bnSenderID, noIcons)))
end

-- Events -----------------------------------------------------------------------------

local handlers = {}
local GROUP_EVENTS = {
    CHAT_MSG_PARTY = "PARTY", CHAT_MSG_PARTY_LEADER = "PARTY_LEADER",
    CHAT_MSG_INSTANCE_CHAT = "INSTANCE_CHAT", CHAT_MSG_INSTANCE_CHAT_LEADER = "INSTANCE_CHAT_LEADER",
    CHAT_MSG_RAID = "RAID", CHAT_MSG_RAID_LEADER = "RAID_LEADER", CHAT_MSG_RAID_WARNING = "RAID_WARNING",
}
for event, chatType in pairs(GROUP_EVENTS) do
    handlers[event] = function(...) OnGroupMessage(chatType, ...) end
end
function handlers.CHAT_MSG_WHISPER(...) OnWhisper("WHISPER", ...) end
function handlers.CHAT_MSG_BN_WHISPER(...) OnWhisper("BN_WHISPER", ...) end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)

-- Preview ----------------------------------------------------------------------------

local SAMPLES = {
    "pull in 10, drink up",
    "oom",
    "Can someone summon? I'm at the meeting stone and it's a long run back.",
    "brb 2 min",
    "nice!",
}

function ns.PreviewChat()
    if not db.enabled then return end
    local _, class = UnitClass("player")
    -- On Forever UnitName returns the surname second; this joins them.
    local name = NameUtil and NameUtil.FormatUnitNameForDisplay and NameUtil.FormatUnitNameForDisplay("player")
        or UnitName("player")
    local function Sample(chatType, text, header)
        local to = REPLY_TYPES[chatType]
        return { text = text, readable = true, color = TypeColor(chatType), tag = TAGS[chatType],
                 header = header, name = name, class = class,
                 reply = { chatType = to, target = to == "WHISPER" and name or nil, label = REPLY_LABELS[to] or name } }
    end
    local onTiles = 0
    for _, tile in ipairs(ns.partyTiles or {}) do
        if tile:IsVisible() then
            onTiles = onTiles + 1
            ShowAtTile(tile, Sample("PARTY", SAMPLES[onTiles], false))
        end
    end
    if onTiles == 0 then
        Push(banner, Sample("PARTY", SAMPLES[1], true))
        print("HoheUI: no party tiles are shown, so party chat went over the column. /hoheui party previews them.")
    end
    Push(banner, Sample("RAID", "Healers, watch the tank on the second phase.", true))
    Push(banner, Sample("RAID_WARNING", "Spread out!", true))
    Push(whispers, Sample("WHISPER", "Hey, are you still looking for a group for Deadmines?", true))
end

ns.AddCommand("chat", "preview the chat bubbles", ns.PreviewChat)

-- Settings ---------------------------------------------------------------------------

local function DismissAll()
    for _, bubble in ipairs(bubbles) do
        if bubble.active then Dismiss(bubble) end
    end
end

-- Lays out the cards on screen again at the new settings.
local function RefreshAll()
    for _, bubble in ipairs(bubbles) do
        if bubble.active then
            Fill(bubble)
            if bubble.tile then AnchorParty(bubble) end
        end
    end
    for _, stack in ipairs({ banner, whispers }) do
        Layout(stack)
        while #stack.cards > stack.Max() do Dismiss(stack.cards[#stack.cards]) end
    end
end

ns.Watch("chat", "enabled", function(on)
    if on then
        for event in pairs(handlers) do events:RegisterEvent(event) end
    else
        events:UnregisterAllEvents()
        DismissAll()
    end
end)
for _, key in ipairs({ "scale", "textSize", "width", "opacity", "partySide", "raidSide", "raidMax",
                       "whisperX", "whisperY", "whisperMax" }) do
    ns.Watch("chat", key, RefreshAll)
end
