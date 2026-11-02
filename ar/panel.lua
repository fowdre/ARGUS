-- The energy panel (AR glasses HUD).
--
-- Same information as the on-screen panel, condensed into a card that does not
-- fight the game view. Redesigned rather than ported: NIDAS drew a full-width
-- bar welded to the bottom of the screen with a dozen chrome quads and an
-- animated charge pulse. This is a compact card with one bar and four fields.
--
-- Glasses objects are created ONCE and mutated per tick. Recreating them every
-- frame leaks objects into the glasses until it chokes — the AR API has no
-- implicit frame boundary.
--
-- The card carries its own ‹ › buttons. OCGlasses has no interactive widget
-- type (no addButton, no onClick — only drawing primitives), so a "button" is a
-- rectangle plus a hit box we test ourselves against the hud_click signal.

local ar = require("lib.graphics.ar")
local palette = require("lib.graphics.colors")
local screen = require("lib.utils.screen")
local text = require("lib.utils.text")

local format = require("ui.format")
local states = require("core.states")

local panel = {}
panel.__index = panel

local WIDTH = 190
local HEIGHT = 34
local COMPACT_WIDTH = 120
local MARGIN = 4

local COMPACT_NAME_CHARS = 10
local COMPACT_PERCENT_CHARS = 7
local COMPACT_STORED_CHARS = 11
local COMPACT_RATE_CHARS = 12
local COMPACT_PROJECTION_CHARS = 17
local COMPACT_STATE_CHARS = 11

-- Where the card sits. Minecraft's own HUD is not negotiable, so the anchor has
-- to be the user's choice: chat occupies the bottom-left, the hotbar and health
-- the bottom-centre, potion effects the top-right. top-left is the default
-- because it is usually the emptiest.
-- "manual" anchors at the origin, which makes offsetX/offsetY absolute
-- coordinates rather than a nudge — for placing the card exactly.
panel.ANCHORS = {
    "top-left", "top-center", "top-right",
    "bottom-left", "bottom-center", "bottom-right",
    "manual",
}

-- How far the bar closes on its target each frame. At the ~10 Hz the HUD
-- refreshes, this reaches the target in about a third of a second: quick enough
-- to feel responsive, slow enough to read as movement rather than a jump.
local BAR_EASE = 0.3

local STATE_COLORS = {
    [states.ONLINE]  = palette.green,
    [states.IDLE]    = palette.muted,
    [states.OFF]     = palette.slate,
    [states.PROBLEM] = palette.amber,
    [states.MISSING] = palette.red,
}

local function anchorPosition(anchor, resolution, width, cardHeight)
    local left = MARGIN
    local center = (resolution[1] - width) / 2
    local right = resolution[1] - width - MARGIN
    local top = MARGIN

    local bottom = resolution[2] - (cardHeight or HEIGHT) - MARGIN

    local positions = {
        ["top-left"]      = {left, top},
        ["top-center"]    = {center, top},
        ["top-right"]     = {right, top},
        ["bottom-left"]   = {left, bottom},
        ["bottom-center"] = {center, bottom},
        ["bottom-right"]  = {right, bottom},
        -- Origin, so the caller's offsets become absolute coordinates.
        ["manual"]        = {0, 0},
    }
    local position = positions[anchor] or positions["top-left"]
    return position[1], position[2]
end

panel.anchorPosition = anchorPosition

local function chargeColor(fraction, theme)
    if fraction == nil then return theme.primary end
    if fraction < 0.10 then return palette.red end
    if fraction < 0.25 then return palette.amber end
    if fraction > 0.95 then return palette.green end
    return theme.primary
end

-- `resolution` is the player's ScaledResolution as {width, height} — the same
-- space hud_click reports its coordinates in, which is what makes the hit boxes
-- below line up without any conversion.
function panel.new(glasses, settings, theme, resolution)
    local compact = settings.compact and true or false
    local scale = ar.hudScale(settings.panelScale)
    local width = (compact and COMPACT_WIDTH or WIDTH) * scale
    local cardHeight = HEIGHT * scale

    -- Snap to the chosen corner, then apply the user's nudge on top.
    local x, y = anchorPosition(settings.anchor, resolution, width, cardHeight)
    x = x + (settings.offsetX or 0)
    y = y + (settings.offsetY or 0)

    local self = setmetatable({
        glasses = glasses,
        theme = theme,
        width = width,
        height = cardHeight,
        x = x,
        y = y,
        static = {},
        dynamic = {},
        regions = {},
        lastColor = nil,
        scale = scale,
        barHeight = 4 * scale,
        headWidth = 2 * scale,
        nameWidth = compact and COMPACT_NAME_CHARS or nil,
        percentWidth = compact and COMPACT_PERCENT_CHARS or nil,
        storedWidth = compact and COMPACT_STORED_CHARS or nil,
        rateWidth = compact and COMPACT_RATE_CHARS or nil,
        projectionWidth = compact and COMPACT_PROJECTION_CHARS or nil,
        stateWidth = compact and COMPACT_STATE_CHARS or nil,
    }, panel)

    local barY = y + 14 * scale
    local barWidth = width - 16 * scale

    -- Chrome
    table.insert(self.static, ar.rectangle(glasses, {x, y}, width, cardHeight, theme.background, 0.55))
    table.insert(self.static, ar.rectangle(glasses, {x, y}, 2 * scale, cardHeight, theme.primary, 0.9))
    table.insert(self.static, ar.rectangle(glasses, {x + 8 * scale, barY}, barWidth, self.barHeight, theme.panel, 0.8))

    -- Source switcher. Hit boxes are deliberately larger than the glyphs: these
    -- are aimed with a free cursor over a busy game view.
    local buttonY = y + 3 * scale
    table.insert(self.static, ar.text(glasses, "‹", {x + 7 * scale, buttonY}, theme.primary, 0.9 * scale))
    table.insert(self.static, ar.text(glasses, "›", {x + 19 * scale, buttonY}, theme.primary, 0.9 * scale))
    self:addRegion(x + 4 * scale, y + 1 * scale, 12 * scale, 12 * scale, "prev")
    self:addRegion(x + 16 * scale, y + 1 * scale, 12 * scale, 12 * scale, "next")

    -- Live fields
    self.dynamic.name = ar.text(glasses, "", {x + 32 * scale, y + 4 * scale}, theme.muted, 0.7 * scale)
    self.dynamic.percent = ar.text(glasses, "", {x + width - 44 * scale, buttonY}, theme.primary, 1.0 * scale)
    self.dynamic.bar = ar.rectangle(glasses, {x + 8 * scale, barY}, scale, self.barHeight, theme.primary, 1.0)
    -- A brighter cap on the leading edge. Without it the fill just stops dead
    -- and the bar reads as clipped rather than as a level.
    self.dynamic.head = ar.rectangle(glasses, {x + 8 * scale, barY}, 2 * scale, self.barHeight, palette.white, 0.85)
    self.dynamic.stored = ar.text(glasses, "", {x + 8 * scale, y + 21 * scale}, palette.text, 0.7 * scale)
    self.dynamic.rate = ar.text(glasses, "", {x + width - 60 * scale, y + 21 * scale}, palette.text, 0.7 * scale)
    self.dynamic.projection = ar.text(glasses, "", {x + 8 * scale, y + 28 * scale}, theme.muted, 0.6 * scale)
    local stateX = compact and x + 72 * scale or x + width - 60 * scale
    self.dynamic.state = ar.text(glasses, "", {stateX, y + 28 * scale}, palette.muted, 0.6 * scale)

    -- Clicking the name toggles cycling, so the whole switcher lives in one place.
    self:addRegion(x + 30 * scale, y + 1 * scale, width - 76 * scale, 12 * scale, "cycle")

    self.barX = x + 8 * scale
    self.barY = barY
    self.barWidth = barWidth

    return self
end

function panel:addRegion(x, y, width, height, action)
    table.insert(self.regions, {x = x, y = y, width = width, height = height, action = action})
end

-- Returns the action under a hud_click, or nil when the click missed the card.
function panel:hitTest(x, y)
    for i = 1, #self.regions do
        local region = self.regions[i]
        if x >= region.x and x < region.x + region.width
            and y >= region.y and y < region.y + region.height then
            return region.action
        end
    end
    return nil
end

function panel:setBar(fraction, color)
    local filled = self.barWidth * math.min(1, math.max(0, fraction or 0))

    -- An empty buffer must render as empty. Clamping to a minimum width left a
    -- permanent sliver at 0%, which looked like a rendering artefact.
    if filled < 0.5 * self.scale then
        self.dynamic.bar.setAlpha(0)
        self.dynamic.head.setAlpha(0)
        return
    end
    self.dynamic.bar.setAlpha(1)

    -- ar.rectangle lays vertices out as TL, BL, BR, TR — so widening the bar
    -- means moving the two right-hand vertices only.
    self.dynamic.bar.setVertex(3, self.barX + filled, self.barY + self.barHeight)
    self.dynamic.bar.setVertex(4, self.barX + filled, self.barY)

    -- Park the cap on the leading edge, and hide it once the bar is full so it
    -- does not hang off the end of the track.
    local headWidth = self.headWidth
    if filled >= self.barWidth - headWidth then
        self.dynamic.head.setAlpha(0)
    else
        self.dynamic.head.setAlpha(0.85)
        local headX = self.barX + filled - headWidth
        self.dynamic.head.setVertex(1, headX, self.barY)
        self.dynamic.head.setVertex(2, headX, self.barY + self.barHeight)
        self.dynamic.head.setVertex(3, headX + headWidth, self.barY + self.barHeight)
        self.dynamic.head.setVertex(4, headX + headWidth, self.barY)
    end

    if color ~= self.lastColor then
        self.dynamic.bar.setColor(screen.toRGB(color))
        self.dynamic.percent.setColor(screen.toRGB(color))
        self.lastColor = color
    end
end

function panel:update(view, cycling)
    if not view then return end

    local fraction = view.percent
    local color = chargeColor(fraction, self.theme)

    -- text.upper, not :upper — string.upper only handles ASCII and would leave
    -- a non-Latin buffer name untouched or mangled.
    local suffix = cycling and " ⟳" or ""
    local name = text.upper(view.name or "?")
    if self.nameWidth then
        name = text.fit(name, math.max(1, self.nameWidth - text.len(suffix)))
    end
    self.dynamic.name.setText(name .. suffix)
    self.dynamic.name.setColor(screen.toRGB(cycling and self.theme.primary or self.theme.muted))

    local percent = format.percent(fraction)
    if self.percentWidth then percent = text.fit(percent, self.percentWidth) end
    self.dynamic.percent.setText(percent)

    -- Glide toward the reading instead of snapping to it. The percentage text
    -- still shows the real value — only the bar is smoothed.
    local target = fraction or 0
    if self.displayed == nil then self.displayed = target end
    self.displayed = self.displayed + (target - self.displayed) * BAR_EASE
    -- Settle exactly, or the bar creeps forever on floating-point remainder.
    if math.abs(target - self.displayed) < 0.0005 then self.displayed = target end
    self:setBar(self.displayed, color)

    -- Glasses text is small and the card is narrow, so exact digits do not fit;
    -- the compact form is the honest choice here.
    local stored = format.compact(view.stored)
    if view.capacity and view.capacity > 0 then
        stored = stored .. " / " .. format.compact(view.capacity)
    end
    if self.storedWidth then stored = text.fit(stored, self.storedWidth) end
    self.dynamic.stored.setText(stored)

    local rate = format.rate(view.net)
    if self.rateWidth then rate = text.fit(rate, self.rateWidth) end
    self.dynamic.rate.setText(rate)
    self.dynamic.rate.setColor(screen.toRGB((view.net or 0) >= 0 and palette.green or palette.red))

    local projectionLabel, projectionValue = format.projection(view.fillSeconds, view.fillDirection)
    if projectionLabel then
        if self.projectionWidth then
            local shortLabel = view.fillDirection == "full" and "Full" or "Empty"
            projectionLabel = text.fit(shortLabel .. " " .. projectionValue, self.projectionWidth)
        else
            projectionLabel = projectionLabel .. " " .. projectionValue
        end
    else
        projectionLabel = ""
    end
    self.dynamic.projection.setText(projectionLabel)

    local state
    if view.state == states.ONLINE or view.state == states.IDLE then
        state = view.problems and view.problems > 0 and "MAINTENANCE" or ""
    else
        state = tostring(view.state or "")
    end
    if self.stateWidth then state = text.fit(state, self.stateWidth) end
    self.dynamic.state.setText(state)
    self.dynamic.state.setColor(screen.toRGB(STATE_COLORS[view.state] or palette.muted))
end

function panel:remove()
    ar.remove(self.glasses, self.static)
    local dynamic = {}
    for _, object in pairs(self.dynamic) do table.insert(dynamic, object) end
    ar.remove(self.glasses, dynamic)
    self.static, self.dynamic, self.regions = {}, {}, {}
end

return panel
