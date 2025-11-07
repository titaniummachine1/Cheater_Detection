---@diagnostic disable: duplicate-set-field, undefined-field

--[[ Advanced Layout Module ]]
-- Solves the TimMenu layout issues by providing proper sector positioning
-- Ensures sectors can be placed side-by-side with consistent spacing

local AdvancedLayout = {}

-- Layout configuration - single source of truth
local Config = {
	DEFAULT_SECTOR_WIDTH = 200,
	SECTOR_SPACING = 10,
	LINE_SPACING = 15,
	PADDING = 8,
}

-- Layout state tracking
local LayoutState = {
	currentX = Config.PADDING,
	currentY = Config.PADDING,
	currentLineSectors = {},
	maxSectorHeightOnLine = 0,
	windowWidth = 0,
}

-- Helper functions
local function resetLine()
	LayoutState.currentX = Config.PADDING
	LayoutState.currentLineSectors = {}
	LayoutState.maxSectorHeightOnLine = 0
end

local function advanceToNextLine()
	LayoutState.currentY = LayoutState.currentY + LayoutState.maxSectorHeightOnLine + Config.LINE_SPACING
	resetLine()
end

local function calculateSectorWidth(title)
	-- Estimate width based on title length
	draw.SetFont(Globals and Globals.Style.Font or "DefaultFont")
	local textWidth = 0
	if pcall(function()
		textWidth = select(1, draw.GetTextSize(title))
	end) then
		return math.max(Config.DEFAULT_SECTOR_WIDTH, textWidth + Config.PADDING * 4)
	end
	return Config.DEFAULT_SECTOR_WIDTH
end

-- Public API
function AdvancedLayout.BeginSector(title, customWidth)
	local sectorWidth = customWidth or calculateSectorWidth(title)

	-- Store sector info
	local sectorInfo = {
		title = title,
		x = LayoutState.currentX,
		y = LayoutState.currentY,
		width = sectorWidth,
		height = 0, -- Will be calculated at end
	}

	table.insert(LayoutState.currentLineSectors, sectorInfo)

	-- Begin the sector with custom positioning if possible
	if TimMenu.SetCursor then
		TimMenu.SetCursor(LayoutState.currentX, LayoutState.currentY)
	end

	TimMenu.BeginSector(title)

	return sectorInfo
end

function AdvancedLayout.EndSector(moveToNextPosition)
	local sectorInfo = LayoutState.currentLineSectors[#LayoutState.currentLineSectors]
	if sectorInfo then
		-- Estimate sector height (simplified)
		sectorInfo.height = 50 -- Base height
		LayoutState.maxSectorHeightOnLine = math.max(LayoutState.maxSectorHeightOnLine, sectorInfo.height)
	end

	TimMenu.EndSector()

	if moveToNextPosition ~= false then
		AdvancedLayout.MoveToNextPosition()
	end
end

function AdvancedLayout.MoveToNextPosition(sameLine)
	if sameLine then
		-- Move to the right on the same line
		local lastSector = LayoutState.currentLineSectors[#LayoutState.currentLineSectors]
		if lastSector then
			LayoutState.currentX = lastSector.x + lastSector.width + Config.SECTOR_SPACING
		end
	else
		-- Move to next line
		advanceToNextLine()
	end
end

function AdvancedLayout.FinalizeLine()
	advanceToNextLine()
end

function AdvancedLayout.CreateSectorRow(sectors)
	for i, sectorData in ipairs(sectors) do
		local isLast = (i == #sectors)
		AdvancedLayout.BeginSector(sectorData.title, sectorData.width)

		if sectorData.content then
			sectorData.content()
		end

		AdvancedLayout.EndSector(not isLast) -- Don't move to next position for last sector
	end

	AdvancedLayout.FinalizeLine()
end

function AdvancedLayout.CreateCheckbox(label, configTable, fieldPath, tooltip)
	local value = configTable[fieldPath] or false
	local result = TimMenu.Checkbox(label, value)
	configTable[fieldPath] = result

	if tooltip then
		TimMenu.Tooltip(tooltip)
	end

	return result
end

function AdvancedLayout.CreateSlider(label, configTable, fieldPath, minVal, maxVal, defaultValue, step, tooltip)
	local value = configTable[fieldPath] or defaultValue
	local result = TimMenu.Slider(label, value, minVal, maxVal, step or 1)
	configTable[fieldPath] = result

	if tooltip then
		TimMenu.Tooltip(tooltip)
	end

	return result
end

function AdvancedLayout.CreateCombo(label, options, configTable, fieldPath, tooltip)
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

function AdvancedLayout.CreateMultiCombo(label, options, configTable, fieldPath, tooltip)
	local result = {}

	-- Initialize all options to true if not set
	for i, option in ipairs(options) do
		local key = fieldPath .. "_" .. option:gsub("%s+", "_")
		result[i] = configTable[key] ~= false -- Default to true
	end

	result = TimMenu.Combo(label, result, options)

	-- Update config with new values
	for i, option in ipairs(options) do
		local key = fieldPath .. "_" .. option:gsub("%s+", "_")
		configTable[key] = result[i]
	end

	if tooltip then
		TimMenu.Tooltip(tooltip)
	end

	return result
end

function AdvancedLayout.CreateConditionalSection(title, condition, contentFunc, sameLine)
	if condition then
		AdvancedLayout.BeginSector(title)

		if contentFunc then
			contentFunc()
		end

		AdvancedLayout.EndSector(not sameLine)
	end
end

function AdvancedLayout.StandardizeSpacing()
	TimMenu.NextLine()
end

-- Configuration management
function AdvancedLayout.GetConfig()
	return Config
end

function AdvancedLayout.UpdateConfig(newConfig)
	for key, value in pairs(newConfig) do
		if Config[key] ~= nil then
			Config[key] = value
		end
	end
end

function AdvancedLayout.ResetLayout()
	LayoutState.currentX = Config.PADDING
	LayoutState.currentY = Config.PADDING
	LayoutState.currentLineSectors = {}
	LayoutState.maxSectorHeightOnLine = 0
end

-- Utility functions for common patterns
function AdvancedLayout.CreateOutputSection(title, configTable, fieldPrefix)
	local outputOptions = { "Public Chat", "Party Chat", "Client Chat", "Console" }

	AdvancedLayout.BeginSector(title)

	-- Initialize output fields if needed
	if not configTable.Output then
		configTable.Output = {}
	end

	local outputTable = {}
	for i, option in ipairs(outputOptions) do
		local key = fieldPrefix .. option:gsub("%s+", "")
		if fieldPrefix == "" then
			-- For empty prefix, use the option names directly
			outputTable[i] = configTable.Output[option] ~= false
		else
			outputTable[i] = configTable.Output[key] ~= false
		end
	end

	outputTable = TimMenu.Combo(title .. " Output", outputTable, outputOptions)

	-- Update config
	for i, option in ipairs(outputOptions) do
		local key = fieldPrefix .. option:gsub("%s+", "")
		if fieldPrefix == "" then
			configTable.Output[option] = outputTable[i]
		else
			configTable.Output[key] = outputTable[i]
		end
	end

	AdvancedLayout.EndSector()
end

function AdvancedLayout.CreateTabbedSection(tabs, currentTab, contentFuncs)
	local result = TimMenu.TabControl("advanced_tabs", tabs, currentTab)
	AdvancedLayout.StandardizeSpacing()

	if contentFuncs[result] then
		AdvancedLayout.ResetLayout() -- Reset layout for new tab content
		contentFuncs[result]()
	end

	return result
end

return AdvancedLayout
