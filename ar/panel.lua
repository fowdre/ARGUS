-- The energy panel (AR glasses HUD).
--
-- Same information as the on-screen panel, condensed into a card that does not
-- fight the game view. Redesigned rather than ported: NIDAS drew a full-width
-- bar welded to the bottom of the screen with a dozen chrome quads and an
-- animated charge pulse. This is a compact card with one bar, four fields, and
-- an optional charge-history graph.
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

local metrics = require("core.metrics")
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

local GRAPH_SAMPLES = 120
local GRAPH_COLUMNS = 60
local GRAPH_SAMPLES_PER_COLUMN = GRAPH_SAMPLES / GRAPH_COLUMNS
local GRAPH_PAINT_INTERVAL = 0.5

local GRAPH_HEIGHT_DEFAULT = 24
local GRAPH_HEIGHT_MIN = 8
local GRAPH_HEIGHT_MAX = 48
local GRAPH_HEIGHTS = {16, 20, 24, 28, 32, 36}

local GRAPH_PLOT_X = 8
local GRAPH_PLOT_Y = 24
local GRAPH_PLOT_WIDTH = 144
local GRAPH_LABEL_X = 156
local GRAPH_LABEL_WIDTH = 26
local GRAPH_LABEL_SCALE = 0.5
local GRAPH_CAPTION_Y = 19.2
local GRAPH_CAPTION_SCALE = 0.5
local GRAPH_MESSAGE_SCALE = 0.6
local GRAPH_STORED_GAP = 2
local GRAPH_PROJECTION_GAP = 6
local GRAPH_BOTTOM_PAD = 6
local GRAPH_MUTED_BLEND = 0.5

local GRAPH_TOGGLE_RIGHT_INSET = 6
local GRAPH_TOGGLE_Y = 13.8
local GRAPH_TOGGLE_SCALE = 0.6
local GRAPH_TOGGLE_REGION_X_INSET = 14
local GRAPH_TOGGLE_REGION_Y = 11.5
local GRAPH_TOGGLE_REGION_WIDTH = 14
local GRAPH_TOGGLE_REGION_HEIGHT = 12

panel.GRAPH_HEIGHTS = GRAPH_HEIGHTS
panel.GRAPH_HEIGHT_DEFAULT = GRAPH_HEIGHT_DEFAULT

local function clampGraphHeight(value)
    value = math.floor(tonumber(value) or GRAPH_HEIGHT_DEFAULT)
    if value < GRAPH_HEIGHT_MIN then value = GRAPH_HEIGHT_MIN end
    if value > GRAPH_HEIGHT_MAX then value = GRAPH_HEIGHT_MAX end
    return value
end

panel.clampGraphHeight = clampGraphHeight

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
    local graphHidden = not compact and (settings.graphHidden and true or false)
    local plotHeight = 0
    local storedY = 21
    local projectionY = 28
    local cardUnits = HEIGHT
    if not compact and not graphHidden then
        plotHeight = clampGraphHeight(settings.graphHeight)
        storedY = GRAPH_PLOT_Y + plotHeight + GRAPH_STORED_GAP
        projectionY = storedY + GRAPH_PROJECTION_GAP
        cardUnits = projectionY + GRAPH_BOTTOM_PAD
    end
    local cardHeight = cardUnits * scale

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
        graphHidden = graphHidden,
        graphColumns = {},
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

    if not compact then
        local glyph = graphHidden and "▼" or "▲"
        table.insert(self.static, ar.text(glasses, glyph,
            {x + width - GRAPH_TOGGLE_RIGHT_INSET * scale, y + GRAPH_TOGGLE_Y * scale},
            theme.primary, GRAPH_TOGGLE_SCALE * scale))
    end

    -- Live fields
    self.dynamic.name = ar.text(glasses, "", {x + 32 * scale, y + 4 * scale}, theme.muted, 0.7 * scale)
    self.dynamic.percent = ar.text(glasses, "", {x + width - 44 * scale, buttonY}, theme.primary, 1.0 * scale)
    self.dynamic.bar = ar.rectangle(glasses, {x + 8 * scale, barY}, scale, self.barHeight, theme.primary, 1.0)
    -- A brighter cap on the leading edge. Without it the fill just stops dead
    -- and the bar reads as clipped rather than as a level.
    self.dynamic.head = ar.rectangle(glasses, {x + 8 * scale, barY}, 2 * scale, self.barHeight, palette.white, 0.85)
    self.dynamic.stored = ar.text(glasses, "", {x + 8 * scale, y + storedY * scale}, palette.text, 0.7 * scale)
    self.dynamic.rate = ar.text(glasses, "", {x + width - 60 * scale, y + storedY * scale}, palette.text, 0.7 * scale)
    self.dynamic.projection = ar.text(glasses, "", {x + 8 * scale, y + projectionY * scale}, theme.muted, 0.6 * scale)
    local stateX = compact and x + 72 * scale or x + width - 60 * scale
    self.dynamic.state = ar.text(glasses, "", {stateX, y + projectionY * scale}, palette.muted, 0.6 * scale)

    -- Clicking the name toggles cycling, so the whole switcher lives in one place.
    self:addRegion(x + 30 * scale, y + 1 * scale, width - 76 * scale, 12 * scale, "cycle")

    if not compact then
        self:addRegion(
            x + width - GRAPH_TOGGLE_REGION_X_INSET * scale,
            y + GRAPH_TOGGLE_REGION_Y * scale,
            GRAPH_TOGGLE_REGION_WIDTH * scale,
            GRAPH_TOGGLE_REGION_HEIGHT * scale,
            "graph")
    end

    if plotHeight > 0 then
        local graph = {
            columns = GRAPH_COLUMNS,
            plotX = x + GRAPH_PLOT_X * scale,
            plotY = y + GRAPH_PLOT_Y * scale,
            plotWidth = GRAPH_PLOT_WIDTH * scale,
            plotHeight = plotHeight * scale,
            values = {},
            columnHeight = {},
            columnX0 = {},
            columnX1 = {},
            visibleColumns = 0,
        }
        graph.caption = ar.text(glasses, "",
            {x + GRAPH_PLOT_X * scale, y + GRAPH_CAPTION_Y * scale},
            theme.muted, GRAPH_CAPTION_SCALE * scale)
        graph.maxLabel = ar.text(glasses, "",
            {x + GRAPH_LABEL_X * scale, y + GRAPH_PLOT_Y * scale},
            theme.muted, GRAPH_LABEL_SCALE * scale)

        graph.minLabel = ar.text(glasses, "",
            {x + GRAPH_LABEL_X * scale, y + (GRAPH_PLOT_Y + plotHeight - 5) * scale},
            theme.muted, GRAPH_LABEL_SCALE * scale)
        graph.message = ar.text(glasses, "",
            {x + GRAPH_PLOT_X * scale, y + (GRAPH_PLOT_Y + (plotHeight - 5) / 2) * scale},
            theme.muted, GRAPH_MESSAGE_SCALE * scale)
        self.graph = graph

        for i = 1, GRAPH_COLUMNS do
            self.graphColumns[i] = ar.quad(glasses)
        end
    end

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

function panel:updateGraph(view, now)
    local graph = self.graph
    if not graph then return end

    local function setMessage(value)
        if graph.messageText ~= value then
            graph.message.setText(value)
            graph.messageText = value
        end
    end

    local function setBounds(maxText, minText)
        local labelRight = self.x + (GRAPH_LABEL_X + GRAPH_LABEL_WIDTH) * self.scale
        local labelWidth = GRAPH_LABEL_SCALE * self.scale * 6
        local labelTop = self.y + GRAPH_PLOT_Y * self.scale
        if maxText ~= graph.maxText then
            graph.maxLabel.setText(maxText)
            graph.maxLabel.setPosition(labelRight - text.len(maxText) * labelWidth, labelTop)
            graph.maxText = maxText
        end
        if minText ~= graph.minText then
            graph.minLabel.setText(minText)
            graph.minLabel.setPosition(labelRight - text.len(minText) * labelWidth,
                labelTop + graph.plotHeight - 5 * self.scale)
            graph.minText = minText
        end
    end

    local function hideAll()
        if graph.visibleColumns ~= 0 then
            for i = 1, GRAPH_COLUMNS do
                if graph.columnHeight[i] then
                    self.graphColumns[i].setAlpha(0)
                    graph.columnHeight[i] = nil
                end
            end
            graph.visibleColumns = 0
            graph.laidOutStart = nil
        end
    end

    local tracker = view.tracker
    if not tracker then
        graph.tracker, graph.key = nil, nil
        hideAll()
        setMessage("collecting data…")
        setBounds("", "")
        return
    end

    local series = metrics.series(tracker)
    local interval = tracker.graphInterval or 0

    if graph.interval ~= interval then
        graph.interval = interval
        graph.caption.setText("Charge · last " ..
            format.window(math.floor(interval * GRAPH_SAMPLES + 0.5)))
    end

    local capacity = tonumber(view.capacity)
    local fixedMax = (capacity and capacity > 0) and capacity or nil
    local scaleKey = fixedMax and ("fixed:" .. tostring(fixedMax)) or "auto"

    local key = tostring(series.count) .. ":" .. tostring(series.head) .. ":" .. scaleKey
    local trackerChanged = graph.tracker ~= tracker
    if not trackerChanged and graph.key == key then return end

    if now and graph.lastPaint and (now - graph.lastPaint) < GRAPH_PAINT_INTERVAL then
        return
    end
    graph.tracker, graph.key, graph.lastPaint = tracker, key, now

    if trackerChanged then
        graph.visibleColumns = -1 -- forces a full layout below
        graph.maxText, graph.minText = nil, nil
    end

    local count = series.count
    if count < 2 then
        hideAll()
        setMessage("collecting data…")
        setBounds("", "")
        return
    end

    local samples = math.min(count, GRAPH_SAMPLES)
    local first = count - samples + 1
    local columns = math.min(GRAPH_COLUMNS, math.ceil(samples / GRAPH_SAMPLES_PER_COLUMN))
    local startColumn = GRAPH_COLUMNS - columns + 1

    local values = graph.values
    local min, max
    for column = 1, columns do
        local from = first + (column - 1) * GRAPH_SAMPLES_PER_COLUMN
        local to = math.min(from + GRAPH_SAMPLES_PER_COLUMN - 1, count)
        local sum, n = 0, 0
        for i = from, to do
            local _, value = series:get(i)
            if value then
                sum = sum + value
                n = n + 1
            end
        end
        local value = n > 0 and (sum / n) or nil
        values[column] = value
        if value then
            if not min or value < min then min = value end
            if not max or value > max then max = value end
        end
    end

    if not min then
        hideAll()
        setMessage("collecting data…")
        setBounds("", "")
        return
    end
    setMessage("")

    local span = max - min
    local bottom = graph.plotY + graph.plotHeight
    local step = graph.plotWidth / GRAPH_COLUMNS
    local muted = screen.blend(self.theme.muted, self.theme.background, GRAPH_MUTED_BLEND)

    local function heightFor(value)
        local fraction
        if fixedMax then
            fraction = value / fixedMax
            if fraction < 0 then fraction = 0
            elseif fraction > 1 then fraction = 1 end
        else
            fraction = (span <= 0) and 0.5 or (value - min) / span
        end
        return math.max(1, math.floor(fraction * graph.plotHeight + 0.5))
    end

    local function paintColumn(index, height)
        local x0 = graph.columnX0[index]
        local x1 = graph.columnX1[index]
        if not x0 then
            x0 = graph.plotX + (index - 1) * step
            x1 = x0 + step
            graph.columnX0[index], graph.columnX1[index] = x0, x1
        end
        local y0 = bottom - height
        local column = self.graphColumns[index]
        column.setVertex(1, x0, y0)
        column.setVertex(2, x0, bottom)
        column.setVertex(3, x1, bottom)
        column.setVertex(4, x1, y0)
        column.setColor(screen.toRGB(screen.blend(muted, self.theme.primary,
            height / graph.plotHeight)))
        column.setAlpha(1)
        graph.columnHeight[index] = height
    end

    local layoutChanged = graph.visibleColumns ~= columns
        or graph.laidOutStart ~= startColumn

    if layoutChanged then
        for i = 1, startColumn - 1 do
            if graph.columnHeight[i] then
                self.graphColumns[i].setAlpha(0)
                graph.columnHeight[i] = nil
            end
        end
        for i = startColumn + columns, GRAPH_COLUMNS do
            if graph.columnHeight[i] then
                self.graphColumns[i].setAlpha(0)
                graph.columnHeight[i] = nil
            end
        end

        for column = 1, columns do
            local index = startColumn + column - 1
            local value = values[column]
            if value == nil then
                if graph.columnHeight[index] then
                    self.graphColumns[index].setAlpha(0)
                    graph.columnHeight[index] = nil
                end
            else
                graph.columnX0[index] = graph.plotX + (index - 1) * step
                graph.columnX1[index] = graph.columnX0[index] + step
                paintColumn(index, heightFor(value))
            end
        end
        graph.visibleColumns = columns
        graph.laidOutStart = startColumn
    else
        for column = 1, columns do
            local index = startColumn + column - 1
            local value = values[column]
            if value == nil then
                if graph.columnHeight[index] then
                    self.graphColumns[index].setAlpha(0)
                    graph.columnHeight[index] = nil
                end
            else
                local height = heightFor(value)
                if graph.columnHeight[index] == nil then
                    paintColumn(index, height)
                elseif graph.columnHeight[index] ~= height then
                    local y0 = bottom - height
                    local object = self.graphColumns[index]
                    object.setVertex(1, graph.columnX0[index], y0)
                    object.setVertex(4, graph.columnX1[index], y0)
                    object.setColor(screen.toRGB(screen.blend(muted, self.theme.primary,
                        height / graph.plotHeight)))
                    graph.columnHeight[index] = height
                end
            end
        end
    end

    if fixedMax then
        setBounds(format.compact(fixedMax), format.compact(0))
    else
        setBounds(format.compact(max), format.compact(min))
    end
end

function panel:update(view, cycling, now)
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

    self:updateGraph(view, now)
end

function panel:remove()
    ar.remove(self.glasses, self.static)
    local dynamic = {}
    for _, object in pairs(self.dynamic) do table.insert(dynamic, object) end
    for i = 1, #self.graphColumns do table.insert(dynamic, self.graphColumns[i]) end
    if self.graph then
        table.insert(dynamic, self.graph.caption)
        table.insert(dynamic, self.graph.maxLabel)
        table.insert(dynamic, self.graph.minLabel)
        table.insert(dynamic, self.graph.message)
    end
    ar.remove(self.glasses, dynamic)
    self.static, self.dynamic, self.regions = {}, {}, {}
    self.graph, self.graphColumns = nil, {}
end

return panel
