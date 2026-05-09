local HttpQueue = require("Cheater_Detection.services.http_queue")

local BridgePrompt = {}

local PROMPT_DURATION = 15.0
local PROMPT_TITLE = "Local Bridge Recommended"
local PROMPT_LINE_1 = "To avoid in-game lag during database updates,"
local PROMPT_LINE_2 = "please run 'StartLocalBridge.bat' in your project folder."
local PROMPT_LINE_3 = "Click anywhere to dismiss this reminder."

local expiresAt = 0.0
local dismissed = false

local cachedMeasurements = {
    screenWidth = 0,
    screenHeight = 0,
    titleWidth = 0,
    titleHeight = 0,
    line1Width = 0,
    line1Height = 0,
    line2Width = 0,
    line2Height = 0,
    line3Width = 0,
    line3Height = 0,
    boxWidth = 0,
    boxHeight = 0,
    lastUpdate = 0
}

local function UpdateMeasurements(now)
    local screenWidth, screenHeight = draw.GetScreenSize()
    local titleWidth, titleHeight = draw.GetTextSize(PROMPT_TITLE)
    local line1Width, line1Height = draw.GetTextSize(PROMPT_LINE_1)
    local line2Width, line2Height = draw.GetTextSize(PROMPT_LINE_2)
    local line3Width, line3Height = draw.GetTextSize(PROMPT_LINE_3)

    local contentWidth = titleWidth
    if line1Width > contentWidth then contentWidth = line1Width end
    if line2Width > contentWidth then contentWidth = line2Width end
    if line3Width > contentWidth then contentWidth = line3Width end

    local padding = 12
    local lineGap = 4
    local boxWidth = contentWidth + padding * 2
    local textHeight = titleHeight + line1Height + line2Height + line3Height + lineGap * 3
    local boxHeight = textHeight + padding * 2 + 4

    cachedMeasurements.screenWidth = screenWidth
    cachedMeasurements.screenHeight = screenHeight
    cachedMeasurements.titleWidth = titleWidth
    cachedMeasurements.titleHeight = titleHeight
    cachedMeasurements.line1Width = line1Width
    cachedMeasurements.line1Height = line1Height
    cachedMeasurements.line2Width = line2Width
    cachedMeasurements.line2Height = line2Height
    cachedMeasurements.line3Width = line3Width
    cachedMeasurements.line3Height = line3Height
    cachedMeasurements.boxWidth = boxWidth
    cachedMeasurements.boxHeight = boxHeight
    cachedMeasurements.lastUpdate = now
end

local function Now()
    local globalsTable = globals
    if globalsTable and type(globalsTable.RealTime) == "function" then
        local ok, value = pcall(globalsTable.RealTime)
        if ok and type(value) == "number" then
            return value
        end
    end
    return os.clock()
end

function BridgePrompt.Init()
    expiresAt = Now() + PROMPT_DURATION
    dismissed = false
end

function BridgePrompt.Draw()
    if dismissed then
        return
    end
    local now = Now()
    if HttpQueue and HttpQueue.IsBridgeConfirmed and HttpQueue.IsBridgeConfirmed() then
        dismissed = true
        return
    end
    if now >= expiresAt then
        dismissed = true
        return
    end
    if input.IsButtonPressed(MOUSE_LEFT) then
        dismissed = true
        return
    end

    if now - cachedMeasurements.lastUpdate > 1.0 then
        UpdateMeasurements(now)
    end

    local screenWidth = cachedMeasurements.screenWidth
    local screenHeight = cachedMeasurements.screenHeight
    local titleHeight = cachedMeasurements.titleHeight
    local line1Height = cachedMeasurements.line1Height
    local line2Height = cachedMeasurements.line2Height
    local line3Height = cachedMeasurements.line3Height
    local boxWidth = cachedMeasurements.boxWidth
    local boxHeight = cachedMeasurements.boxHeight

    local padding = 12
    local lineGap = 4
    local x1 = math.floor((screenWidth - boxWidth) * 0.5)
    local y1 = math.floor(screenHeight * 0.12)
    local x2 = x1 + boxWidth
    local y2 = y1 + boxHeight
    local textX = x1 + padding
    local textY = y1 + padding + 4

    draw.Color(20, 22, 28, 225)
    draw.FilledRect(x1, y1, x2, y2)
    draw.Color(255, 170, 70, 255)
    draw.FilledRect(x1, y1, x2, y1 + 4)
    draw.Color(255, 210, 150, 255)
    draw.OutlinedRect(x1, y1, x2, y2)

    draw.Color(255, 240, 210, 255)
    draw.TextShadow(textX, textY, PROMPT_TITLE)
    textY = textY + titleHeight + lineGap

    draw.Color(235, 235, 235, 255)
    draw.TextShadow(textX, textY, PROMPT_LINE_1)
    textY = textY + line1Height + lineGap
    draw.TextShadow(textX, textY, PROMPT_LINE_2)
    textY = textY + line2Height + lineGap
    draw.Color(255, 205, 125, 255)
    draw.TextShadow(textX, textY, PROMPT_LINE_3)
end

return BridgePrompt
