local HttpQueue = require("Cheater_Detection.services.http_queue")

local BridgePrompt = {}

local PROMPT_DURATION = 5.0
local PROMPT_TITLE = "Optional Local Bridge"
local PROMPT_LINE_1 = "Start LocalBridge/StartLocalBridge.bat for smoother real-time HTTP."
local PROMPT_LINE_2 = "Without it, Cheater Detection only uses blocking HTTP in safe moments."
local PROMPT_LINE_3 = "Click anywhere to dismiss."

local expiresAt = 0.0
local dismissed = false

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
    if HttpQueue and HttpQueue.IsBridgeConfirmed and HttpQueue.IsBridgeConfirmed() then
        dismissed = true
        return
    end
    if Now() >= expiresAt then
        dismissed = true
        return
    end
    if input.IsButtonPressed(MOUSE_LEFT) then
        dismissed = true
        return
    end

    local screenWidth, screenHeight = draw.GetScreenSize()
    local titleWidth, titleHeight = draw.GetTextSize(PROMPT_TITLE)
    local line1Width, line1Height = draw.GetTextSize(PROMPT_LINE_1)
    local line2Width, line2Height = draw.GetTextSize(PROMPT_LINE_2)
    local line3Width, line3Height = draw.GetTextSize(PROMPT_LINE_3)

    local contentWidth = titleWidth
    if line1Width > contentWidth then
        contentWidth = line1Width
    end
    if line2Width > contentWidth then
        contentWidth = line2Width
    end
    if line3Width > contentWidth then
        contentWidth = line3Width
    end

    local padding = 12
    local lineGap = 4
    local boxWidth = contentWidth + padding * 2
    local textHeight = titleHeight + line1Height + line2Height + line3Height + lineGap * 3
    local boxHeight = textHeight + padding * 2 + 4
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
