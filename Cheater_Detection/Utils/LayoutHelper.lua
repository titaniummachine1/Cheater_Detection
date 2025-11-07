---@diagnostic disable: duplicate-set-field, undefined-field

--[[ Layout Helper Module ]]
-- Provides systematic layout management following single source of truth principles
-- Eliminates redundant code and ensures consistent element sizing and positioning

local LayoutHelper = {}

-- Configuration constants - single source of truth for all layout values
local Config = {
    SECTOR_SPACING = 10,      -- Spacing between sectors on same line
    LINE_SPACING = 15,        -- Spacing between lines of sectors
    ELEMENT_SPACING = 5,      -- Spacing between elements within sectors
    CHECKBOX_WIDTH = 200,     -- Standard checkbox width
    SLIDER_WIDTH = 200,       -- Standard slider width
    COMBO_WIDTH = 200,        -- Standard combo box width
    BUTTON_WIDTH = 100,       -- Standard button width
    MIN_SECTOR_HEIGHT = 40,   -- Minimum sector height
}

-- Track current line state for height matching
local LineState = {
    sectors = {},             -- Sectors on current line
    maxSectorHeight = 0,      -- Height of tallest sector on current line
    currentLineY = 0,         -- Y position of current line
}

--[[ Helper Functions ]]

local function initializeBooleanField(configTable, fieldPath, defaultValue)
    if type(configTable) ~= "table" then
        return false
    end
    
    local current = configTable
    local keys = {}
    
    -- Split field path by dots
    for key in fieldPath:gmatch("[^%.]+") do
        table.insert(keys, key)
    end
    
    -- Navigate to the nested field
    for i = 1, #keys - 1 do
        current[keys[i]] = current[keys[i]] or {}
        current = current[keys[i]]
    end
    
    local finalKey = keys[#keys]
    if type(current[finalKey]) ~= "boolean" then
        current[finalKey] = defaultValue
    end
    
    return current[finalKey]
end

local function initializeOutputFields(configTable, prefix)
    if not configTable.Output then
        configTable.Output = {}
    end
    
    initializeBooleanField(configTable.Output, prefix .. "PublicChat", false)
    initializeBooleanField(configTable.Output, prefix .. "PartyChat", true)
    initializeBooleanField(configTable.Output, prefix .. "ClientChat", false)
    initializeBooleanField(configTable.Output, prefix .. "Console", true)
end

local function createStandardOutputOptions()
    return { "Public Chat", "Party Chat", "Client Chat", "Console" }
end

local function updateOutputTableFromConfig(outputTable, config)
    outputTable[1] = config.PublicChat
    outputTable[2] = config.PartyChat
    outputTable[3] = config.ClientChat
    outputTable[4] = config.Console
end

local function updateConfigFromOutputTable(config, outputTable)
    config.PublicChat = outputTable[1]
    config.PartyChat = outputTable[2]
    config.ClientChat = outputTable[3]
    config.Console = outputTable[4]
end

--[[ Public API ]]

function LayoutHelper.BeginSector(title)
    TimMenu.BeginSector(title)
    
    -- Track this sector for line height management
    table.insert(LineState.sectors, {
        title = title,
        startY = 0, -- Will be updated when we can get cursor position
        height = 0,
    })
end

function LayoutHelper.EndSector(moveToNextLine)
    TimMenu.EndSector()
    
    -- Update the last sector's height (simplified since we can't track exact heights)
    if #LineState.sectors > 0 then
        local currentSector = LineState.sectors[#LineState.sectors]
        currentSector.height = LayoutHelper.GetConfig().MIN_SECTOR_HEIGHT
        LineState.maxSectorHeight = math.max(LineState.maxSectorHeight, currentSector.height)
    end
    
    if moveToNextLine ~= false then
        LayoutHelper.NextLine()
    end
end

function LayoutHelper.NextLine(spacing)
    local spacingToUse = spacing or Config.LINE_SPACING
    TimMenu.NextLine(spacingToUse)
    
    -- Reset line tracking
    LineState.sectors = {}
    LineState.maxSectorHeight = 0
end

function LayoutHelper.SameLine(spacing)
    local spacingToUse = spacing or Config.SECTOR_SPACING
    -- TimMenu doesn't have SameLine, so we'll use a small spacing approach
    -- This is a limitation we work around by manual positioning
    if TimMenu.SameLine then
        TimMenu.SameLine(spacingToUse)
    end
end

function LayoutHelper.CreateCheckbox(label, configTable, fieldPath, tooltip)
    local value = initializeBooleanField(configTable, fieldPath, false)
    local result = TimMenu.Checkbox(label, value)
    
    -- Update the config with new value
    local current = configTable
    local keys = {}
    for key in fieldPath:gmatch("[^%.]+") do
        table.insert(keys, key)
    end
    
    for i = 1, #keys - 1 do
        current = current[keys[i]]
    end
    current[keys[#keys]] = result
    
    if tooltip then
        TimMenu.Tooltip(tooltip)
    end
    
    return result
end

function LayoutHelper.CreateSlider(label, configTable, fieldPath, minVal, maxVal, defaultValue, step, tooltip)
    local value = configTable[fieldPath] or defaultValue
    local result = TimMenu.Slider(label, value, minVal, maxVal, step or 1)
    configTable[fieldPath] = result
    
    if tooltip then
        TimMenu.Tooltip(tooltip)
    end
    
    return result
end

function LayoutHelper.CreateCombo(label, options, configTable, fieldPath, tooltip)
    local value = configTable[fieldPath]
    if value == nil then
        value = options[1] or false
        configTable[fieldPath] = value
    end
    
    -- Find index of current value
    local currentIndex = 1
    for i, option in ipairs(options) do
        if option == value then
            currentIndex = i
            break
        end
    end
    
    local result = TimMenu.Combo(label, currentIndex, options)
    configTable[fieldPath] = options[result]
    
    if tooltip then
        TimMenu.Tooltip(tooltip)
    end
    
    return options[result]
end

function LayoutHelper.CreateMultiCombo(label, options, configTable, fieldPath, tooltip)
    local result = {}
    
    -- Initialize all options to true if not set
    for i, option in ipairs(options) do
        local key = fieldPath .. "." .. option:gsub("%s+", "_")
        result[i] = initializeBooleanField(configTable, key, true)
    end
    
    result = TimMenu.Combo(label, result, options)
    
    -- Update config with new values
    for i, option in ipairs(options) do
        local key = fieldPath .. "." .. option:gsub("%s+", "_")
        local current = configTable
        local keys = {}
        for k in key:gmatch("[^%.]+") do
            table.insert(keys, k)
        end
        
        for j = 1, #keys - 1 do
            current[keys[j]] = current[keys[j]] or {}
            current = current[keys[j]]
        end
        current[keys[#keys]] = result[i]
    end
    
    if tooltip then
        TimMenu.Tooltip(tooltip)
    end
    
    return result
end

function LayoutHelper.CreateOutputSection(title, configTable, fieldPrefix, defaultValues)
    LayoutHelper.BeginSector(title)
    
    -- Initialize output fields
    initializeOutputFields(configTable, fieldPrefix)
    
    -- Create output combo
    local outputOptions = createStandardOutputOptions()
    local outputTable = {
        configTable.Output[fieldPrefix .. "PublicChat"],
        configTable.Output[fieldPrefix .. "PartyChat"],
        configTable.Output[fieldPrefix .. "ClientChat"],
        configTable.Output[fieldPrefix .. "Console"],
    }
    
    outputTable = TimMenu.Combo(title .. " Output", outputTable, outputOptions)
    
    -- Update config with new values
    updateConfigFromOutputTable(configTable.Output, outputTable)
    
    -- Maintain backwards compatibility
    configTable.PartyChat = configTable.Output[fieldPrefix .. "PartyChat"]
    configTable.Console = configTable.Output[fieldPrefix .. "Console"]
    
    LayoutHelper.EndSector()
end

function LayoutHelper.CreateConditionalSection(title, condition, contentFunc)
    if condition then
        LayoutHelper.BeginSector(title)
        TimMenu.NextLine()
        contentFunc()
        LayoutHelper.EndSector()
        TimMenu.NextLine()
    end
end

function LayoutHelper.CreateTabbedSection(tabs, currentTab, contentFuncs)
    local result = TimMenu.TabControl("layout_tabs", tabs, currentTab)
    LayoutHelper.NextLine()
    
    if contentFuncs[result] then
        contentFuncs[result]()
    end
    
    return result
end

function LayoutHelper.StandardizeElementSpacing()
    TimMenu.NextLine(Config.ELEMENT_SPACING)
end

function LayoutHelper.CreateSectorRow(sectorsData)
    -- Create multiple sectors on the same line
    for i, sectorData in ipairs(sectorsData) do
        LayoutHelper.BeginSector(sectorData.title)
        
        if sectorData.content then
            sectorData.content()
        end
        
        LayoutHelper.EndSector(false) -- Don't move to next line yet
        
        if i < #sectorsData then
            LayoutHelper.SameLine()
        end
    end
    
    LayoutHelper.NextLine() -- Move to next line after all sectors
end

-- Getters for configuration values
function LayoutHelper.GetConfig()
    return Config
end

function LayoutHelper.UpdateConfig(newConfig)
    for key, value in pairs(newConfig) do
        if Config[key] ~= nil then
            Config[key] = value
        end
    end
end

return LayoutHelper
