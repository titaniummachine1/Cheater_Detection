--[[
    Immediate mode menu library for Lmaobox
    Author: github.com/lnx00
    Modified heavily by: github.com/titaniummachine1
]]

--get common.lib
local common = require("Cheater_Detection.Utils.Common")
if not common.Lib then
	error("lnxLib not found. Make sure it's loaded before ImMenu")
end

-- Stack implementation (simple LIFO data structure)
---@class Stack
---@field private items table
Stack = {}
Stack.__index = Stack

-- Error logging helper
local function LogError(message)
	draw.Color(255, 0, 0, 255)
	client.Command(string.format('echo "[ImMenu ERROR] %s"', message))
end

---@return Stack
function Stack.new()
	local self = setmetatable({}, Stack)
	self.items = {}
	return self
end

---@param item any
function Stack:push(item)
	table.insert(self.items, item)
end

---@return any
function Stack:pop()
	if #self.items == 0 then
		return nil
	end
	return table.remove(self.items)
end

---@return any
function Stack:peek()
	if #self.items == 0 then
		return nil
	end
	return self.items[#self.items]
end

local Fonts, Notify = common.Lib.UI.Fonts, common.Lib.UI.Notify
local KeyHelper, Input, Timer = common.Lib.Utils.KeyHelper, common.Lib.Utils.Input, common.Lib.Utils.Timer

-- Annotation aliases
---@alias ImItemID string
---@alias ImPos { X : integer, Y : integer }
---@alias ImWindow { X : integer, Y : integer, W : integer, H : integer, DragPos?: {X: number, Y: number}, IsDragging?: boolean }
---@alias ImFrame { X : integer, Y : integer, W : integer, H : integer, A : integer, TitleHeight?: integer, Title?: string, Children: ImFrame[] }
---@alias ImColorTable table<integer, integer, integer, integer?>

---@class ImColorType
---@field Title ImColorTable
---@field Text ImColorTable
---@field Window ImColorTable
---@field Item ImColorTable
---@field ItemHover ImColorTable
---@field ItemActive ImColorTable
---@field Highlight ImColorTable
---@field HighlightActive ImColorTable
---@field WindowBorder ImColorTable
---@field FrameBorder ImColorTable
---@field Border ImColorTable

---@class ImStyleType
---@field Font Font
---@field ItemPadding number
---@field ItemMargin number
---@field FramePadding number
---@field ItemSize? number[]
---@field WindowBorder boolean
---@field FrameBorder boolean
---@field ButtonBorder boolean
---@field CheckboxBorder boolean
---@field SliderBorder boolean
---@field Border boolean
---@field Popup boolean
---@field Spacing? number[] -- Used in TabControl

--[[ Globals ]]
---@enum ImAlign
ImAlign = { Vertical = 0, Horizontal = 1 }

---@enum ImLayer
ImLayer = { Background = 0, Main = 1, Popup = 2, Tooltip = 3, Top = 4 }

---@class ImMenu
---@field public Cursor ImPos
---@field public ActiveItem ImItemID|nil
ImMenu = {
	Cursor = { X = 0, Y = 0 },
	ActiveItem = nil,
	ActivePopup = nil,
}

--[[ Variables ]]
local screenWidth, screenHeight = draw.GetScreenSize()
local dragPos = { X = 0, Y = 0 }
local lastKey = { Key = 0, Time = 0 }
local inPopup = false

-- Input Helpers
MouseHelper = KeyHelper.new(MOUSE_LEFT)
EnterHelper = KeyHelper.new(KEY_ENTER)
LeftArrow = KeyHelper.new(KEY_LEFT)
RightArrow = KeyHelper.new(KEY_RIGHT)

---@type table<string, ImWindow>
Windows = {}

---@type table<number, function[]> -- Changed from LateDrawList to DrawLayers
DrawLayers = {}

---@type ImColorType
Colors = {
	Title = { 55, 100, 215, 255 },
	Text = { 255, 255, 255, 255 },
	Window = { 30, 30, 30, 255 },
	Item = { 50, 50, 50, 255 },
	ItemHover = { 60, 60, 60, 255 },
	ItemActive = { 70, 70, 70, 255 },
	Highlight = { 180, 180, 180, 100 },
	HighlightActive = { 240, 240, 240, 140 },
	WindowBorder = { 55, 100, 215, 255 },
	FrameBorder = { 0, 0, 0, 200 },
	Border = { 0, 0, 0, 200 },
}

---@type ImStyleType
Style = {
	Font = Fonts.Verdana,
	ItemPadding = 5,
	ItemMargin = 5,
	FramePadding = 5,
	ItemSize = nil,
	WindowBorder = true,
	FrameBorder = false,
	ButtonBorder = false,
	CheckboxBorder = false,
	SliderBorder = false,
	Border = false,
	Popup = false,
	Spacing = { 5, 5 }, -- Default spacing
}

-- Stacks
WindowStack = Stack.new()
FrameStack = Stack.new()
ColorStack = Stack.new()
StyleStack = Stack.new()

--[[ Private Functions ]]

-- Helper function for math.clamp (ensure existence)
local function clamp(x, min, max)
	return math.max(min, math.min(x, max))
end

-- Helper function for math.round (ensure existence)
local function round(num, idp)
	local mult = 10 ^ (idp or 0)
	return math.floor(num * mult + 0.5) / mult
end

---@param color ImColorTable
local function UnpackColor(color)
	-- Ensure components are integers
	return math.floor(color[1]), math.floor(color[2]), math.floor(color[3]), math.floor(color[4] or 255)
end

-- Returns a pressed key suitable for operations (function keys, arrows, etc.)
---@return integer?
function GetOperationKey()
	for i = KEY_F1, KEY_F12 do
		if input.IsButtonDown(i) then
			return i
		end
	end
	for _, key in ipairs({
		KEY_UP,
		KEY_DOWN,
		KEY_LEFT,
		KEY_RIGHT,
		KEY_HOME,
		KEY_END,
		KEY_PAGEUP,
		KEY_PAGEDOWN,
		KEY_INSERT,
		KEY_DELETE,
		KEY_ESCAPE,
	}) do
		if input.IsButtonDown(key) then
			return key
		end
	end
	return nil
end

---@return integer?
local function GetInput()
	local key = Input.GetPressedKey() or GetOperationKey()
	if not key then
		lastKey.Key = 0
		return nil
	end

	if key == lastKey.Key then
		if lastKey.Time + 0.5 < globals.RealTime() then
			return key
		else
			return nil
		end
	end

	lastKey.Key = key
	lastKey.Time = globals.RealTime()
	return key
end

--[[ Public Getters ]]

---@return number
function ImMenu.GetVersion()
	return 0.66
end

---@return ImStyleType
function ImMenu.GetStyle()
	return Style
end

---@return ImColorType
function ImMenu.GetColors()
	return Colors
end

---@return ImWindow
function ImMenu.GetCurrentWindow()
	return WindowStack:peek()
end

---@return ImFrame
function ImMenu.GetCurrentFrame()
	return FrameStack:peek()
end

--[[ Public Setters ]]
-- Push a color to the stack
---@param key string
---@param color ImColorTable
function ImMenu.PushColor(key, color)
	ColorStack:push({ Key = key, Value = Colors[key] })
	Colors[key] = color
end

-- Pop the last color from the stack
---@param amount? integer
function ImMenu.PopColor(amount)
	amount = amount or 1
	for _ = 1, amount do
		local color = ColorStack:pop()
		Colors[color.Key] = color.Value
	end
end

-- Push a style to the stack
---@param key string -- Key should be a string matching a field in ImStyleType
---@param style any  -- Value can be of any type matching the Style field
function ImMenu.PushStyle(key, style)
	StyleStack:push({ Key = key, Value = Style[key] })
	Style[key] = style
end

-- Pop the last style from the stack
---@param amount? integer
function ImMenu.PopStyle(amount)
	amount = amount or 1
	for _ = 1, amount do
		local style = StyleStack:pop()
		Style[style.Key] = style.Value
	end
end

--[[ Public Functions ]]
-- Creates a new color attribute
---@param key string
---@param value any
function ImMenu.AddColor(key, value)
	Colors[key] = value
end

-- Creates a new style attribute
---@param key string
---@param value any
function ImMenu.AddStyle(key, value)
	Style[key] = value
end

-- Executes drawing functions layer by layer from bottom to top
function ImMenu.DrawLayers()
	draw.Color(255, 255, 255, 255)

	-- Get sorted layer keys (from lowest to highest)
	local sortedLayers = {}
	for k in pairs(DrawLayers) do
		table.insert(sortedLayers, k)
	end
	table.sort(sortedLayers)

	-- Run functions layer by layer (from bottom to top)
	for _, layerIndex in ipairs(sortedLayers) do
		if DrawLayers[layerIndex] then
			for _, func in ipairs(DrawLayers[layerIndex]) do
				func()
			end
			DrawLayers[layerIndex] = {} -- Clear layer after drawing
		end
	end
	-- Note: DrawLayers table itself is not cleared, only the function lists within it.
end

-- Updates the cursor and current frame size
---@param w integer
---@param h integer
function ImMenu.UpdateCursor(w, h)
	local frame = ImMenu.GetCurrentFrame()
	if frame then
		if frame.A == 0 then
			-- Horizontal
			ImMenu.Cursor.Y = ImMenu.Cursor.Y + h + Style.ItemMargin
			frame.W = math.max(frame.W, w)
			frame.H = math.floor(math.max(frame.H, ImMenu.Cursor.Y - frame.Y))
		elseif frame.A == 1 then
			-- Vertical
			ImMenu.Cursor.X = ImMenu.Cursor.X + w + Style.ItemMargin
			frame.W = math.max(frame.W, ImMenu.Cursor.X - frame.X)
			frame.H = math.max(frame.H, h)
		end
	else
		-- TODO: It shouldn't be allowed to draw outside of a frame
		ImMenu.Cursor.Y = ImMenu.Cursor.Y + h + Style.ItemMargin
	end
end

-- Updates the next color depending on the interaction state
---@param hovered boolean
---@param active boolean
function ImMenu.InteractionColor(hovered, active)
	if active then
		draw.Color(UnpackColor(Colors.ItemActive))
	elseif hovered then
		draw.Color(UnpackColor(Colors.ItemHover))
	else
		draw.Color(UnpackColor(Colors.Item))
	end
end

---@param width integer
---@param height integer
---@return integer width, integer height
function ImMenu.GetSize(width, height)
	if Style.ItemSize ~= nil then
		width, height = Style.ItemSize[1], Style.ItemSize[2]
	end

	return width, height
end

-- Returns whether the element is clicked or active
---@param x number
---@param y number
---@param width number
---@param height number
---@param id string
---@return boolean hovered, boolean clicked, boolean active
function ImMenu.GetInteraction(x, y, width, height, id)
	-- Check for Escape key to close any active popup
	if input.IsButtonPressed(KEY_ESCAPE) and ImMenu.ActivePopup then
		ImMenu.ActivePopup = nil
		return false, false, false
	end

	-- Is a different element active?
	if ImMenu.ActiveItem ~= nil and ImMenu.ActiveItem ~= id then
		return false, false, false
	end

	-- Is a popup active? (Skip this check if processing click-through)
	if ImMenu.ActivePopup ~= nil and not inPopup and not justClosedPopup then
		return false, false, false
	end

	local hovered = Input.MouseInBounds(x, y, x + width, y + height) or id == ImMenu.ActiveItem
	local clicked = hovered and (MouseHelper:Released() or EnterHelper:Released()) -- Use Released() for click detection
	local active = hovered and (MouseHelper:Down() or EnterHelper:Down())

	-- Should this element be active?
	if active and ImMenu.ActiveItem == nil then
		ImMenu.ActiveItem = id
	end

	-- Is this element no longer active?
	if ImMenu.ActiveItem == id and not active then
		ImMenu.ActiveItem = nil
	end

	return hovered, clicked, active
end

---@param text string
function ImMenu.GetLabel(text)
	for label in text:gmatch("(.+)###(.+)") do
		return label
	end

	return text
end

---@param size? number
function ImMenu.Space(size)
	size = size or Style.ItemMargin
	ImMenu.UpdateCursor(size, size)
end

function ImMenu.Separator()
	local x, y = math.floor(ImMenu.Cursor.X), math.floor(ImMenu.Cursor.Y)
	local currentWindow = ImMenu.GetCurrentWindow()
	if not currentWindow then
		return
	end -- Add nil check
	local width = math.floor(currentWindow.W - Style.FramePadding * 2)
	local height = math.floor(Style.ItemMargin * 2)

	draw.Color(UnpackColor(Colors.WindowBorder))
	-- Ensure integer coordinates for line drawing
	draw.Line(x, math.floor(y + height / 2), x + width, math.floor(y + height / 2))

	ImMenu.UpdateCursor(width, height)
end

-- Begins a new frame
---@param titleOrAlign string|integer
---@param align? integer
function ImMenu.BeginFrame(titleOrAlign, align)
	local title = nil
	if type(titleOrAlign) == "string" then
		title = titleOrAlign
	elseif type(titleOrAlign) == "number" then
		align = titleOrAlign
	end
	align = align or 0

	local frame = {
		X = math.floor(ImMenu.Cursor.X),
		Y = math.floor(ImMenu.Cursor.Y),
		W = 0,
		H = 0,
		A = align,
		Title = title,
		Children = {},
	}

	FrameStack:push(frame)

	-- Apply padding
	ImMenu.Cursor.X = math.floor(ImMenu.Cursor.X + Style.FramePadding)
	ImMenu.Cursor.Y = math.floor(ImMenu.Cursor.Y + Style.FramePadding)

	-- Draw title if provided
	if title then
		local txtWidth, txtHeight = draw.GetTextSize(title)
		frame.TitleHeight = math.floor(txtHeight + Style.FramePadding * 2)

		local currentWindow = ImMenu.GetCurrentWindow()
		if not currentWindow then
			return
		end -- Add nil check
		local frameWidth = math.floor(currentWindow.W - Style.FramePadding * 4)

		-- Draw title background
		draw.Color(UnpackColor(Colors.Title))
		draw.FilledRect(frame.X, frame.Y, frame.X + frameWidth, frame.Y + frame.TitleHeight)

		-- Draw title text centered
		draw.Color(UnpackColor(Colors.Text))
		local textX = math.floor(frame.X + (frameWidth - txtWidth) / 2)
		draw.Text(textX, math.floor(frame.Y + Style.FramePadding), title)

		-- Draw frame background
		draw.Color(UnpackColor(Colors.Title))
		draw.FilledRect(
			frame.X,
			frame.Y + frame.TitleHeight,
			frame.X + frameWidth,
			math.floor(frame.Y + frame.H + frame.TitleHeight)
		)

		ImMenu.Space(5)
		ImMenu.Cursor.Y = math.floor(ImMenu.Cursor.Y + frame.TitleHeight + Style.ItemMargin)
	end
end

-- Ends the current frame
---@return ImFrame frame
function ImMenu.EndFrame()
	---@type ImFrame
	local frame = FrameStack:pop()

	-- Process children
	for _, child in ipairs(frame.Children) do
		child.W = math.floor(math.max(child.W, ImMenu.Cursor.X - child.X))
		child.H = math.floor(ImMenu.Cursor.Y - child.Y)
		frame.W = math.floor(math.max(frame.W, child.W))
		frame.H = math.floor(frame.H + child.H + Style.ItemMargin)

		-- Draw child frame background and border
		draw.Color(UnpackColor(Colors.Item))
		draw.FilledRect(child.X, child.Y, child.X + child.W, child.Y + child.H)
		if Style.FrameBorder then
			draw.Color(UnpackColor(Colors.FrameBorder))
			draw.OutlinedRect(child.X, child.Y, child.X + child.W, child.Y + child.H)
		end
	end

	ImMenu.Cursor.X = frame.X
	ImMenu.Cursor.Y = frame.Y

	-- Apply padding
	if frame.A == 0 then
		frame.W = math.floor(frame.W + Style.FramePadding * 2)
		frame.H = math.floor(frame.H + Style.FramePadding - Style.ItemMargin)
	elseif frame.A == 1 then
		frame.H = math.floor(frame.H + Style.FramePadding * 2)
		frame.W = math.floor(frame.W + Style.FramePadding - Style.ItemMargin)
	end

	-- Update the cursor
	ImMenu.UpdateCursor(frame.W, frame.H)

	return frame
end

-- Load a bold font
local BoldFont = draw.CreateFont("Verdana Bold", 18, 800)

-- Begins a new window
---@param title string
---@param visible? boolean
---@return boolean visible
function ImMenu.Begin(title, visible)
	local isVisible = (visible == nil) or visible
	if not isVisible then
		return false
	end

	-- Process any delayed clicks from previous frame
	ImMenu.ProcessClickAfterPopupClose()

	-- Create the window if it doesn't exist
	if not Windows[title] then
		Windows[title] = {
			X = 50,
			Y = 150,
			W = 100,
			H = 100,
		}
	end

	-- Initialize the window
	local window = Windows[title]
	draw.SetFont(BoldFont) -- Set the bold font before getting text size
	local titleText = ImMenu.GetLabel(title)
	local txtWidth, txtHeight = draw.GetTextSize(titleText)
	local titleHeight = math.floor(txtHeight + (Style.ItemPadding or 5))
	-- Ensure integer coordinates for interaction check
	local ix, iy, iw, ih = math.floor(window.X), math.floor(window.Y), math.floor(window.W), math.floor(titleHeight)
	local hovered, clicked, active = ImMenu.GetInteraction(ix, iy, iw, ih, title)

	-- Title bar
	draw.Color(table.unpack(Colors.Title))
	-- Ensure integer coordinates for drawing
	draw.OutlinedRect(
		math.floor(window.X),
		math.floor(window.Y),
		math.floor(window.X + window.W),
		math.floor(window.Y + window.H)
	)
	draw.FilledRect(
		math.floor(window.X),
		math.floor(window.Y),
		math.floor(window.X + window.W),
		math.floor(window.Y + titleHeight)
	)

	-- Title text with shadow and bold font
	local titleX = math.floor(window.X + (window.W / 2) - (txtWidth / 2))
	local titleY = math.floor(window.Y + (titleHeight / 2) - (txtHeight / 2))

	draw.TextShadow(titleX + 1, titleY + 1, titleText)
	draw.Color(255, 255, 255, 255)
	draw.Text(titleX, titleY, titleText)

	-- Background
	draw.Color(table.unpack(Colors.Window))
	draw.FilledRect(
		math.floor(window.X),
		math.floor(window.Y + titleHeight),
		math.floor(window.X + window.W),
		math.floor(window.Y + window.H + titleHeight)
	)

	-- Border
	if Style.WindowBorder then
		draw.Color(UnpackColor(Colors.WindowBorder))
		draw.OutlinedRect(
			math.floor(window.X),
			math.floor(window.Y),
			math.floor(window.X + window.W),
			math.floor(window.Y + window.H + titleHeight)
		)
		draw.Line(
			math.floor(window.X),
			math.floor(window.Y + titleHeight),
			math.floor(window.X + window.W),
			math.floor(window.Y + titleHeight)
		)
	end

	-- Mouse drag
	local mousePos = input.GetMousePos()
	local mX, mY = table.unpack(mousePos or { window.X, window.Y }) -- Provide default if nil
	mX = (type(mX) == "number" and mX) or window.X -- Ensure mX is a number
	mY = (type(mY) == "number" and mY) or window.Y -- Ensure mY is a number

	if clicked then
		window.DragPos = { X = mX - window.X, Y = mY - window.Y }
		window.IsDragging = true
	elseif not input.IsButtonDown(MOUSE_LEFT) and not clicked then
		window.IsDragging = false
	end

	if window.IsDragging then
		-- Ensure DragPos exists and is valid before using it
		local dragX = (window.DragPos and type(window.DragPos.X) == "number" and window.DragPos.X) or 0
		local dragY = (window.DragPos and type(window.DragPos.Y) == "number" and window.DragPos.Y) or 0
		-- Ensure clamped values are integers
		window.X = math.floor(clamp(mX - dragX, 0, screenWidth - window.W))
		window.Y = math.floor(clamp(mY - dragY, 0, screenHeight - window.H - titleHeight))
	end

	-- Update the cursor
	ImMenu.Cursor.X = math.floor(window.X)
	ImMenu.Cursor.Y = math.floor(window.Y + titleHeight)

	---@diagnostic disable-next-line: missing-parameter -- Add disable for linter error
	ImMenu.BeginFrame()

	-- Store and push the window
	Windows[title] = window
	WindowStack:push(window)

	return true
end

-- Ends the current window
---@return ImWindow
function ImMenu.End()
	---@type ImFrame
	---@diagnostic disable-next-line: missing-parameter -- Re-add disable for linter error
	local frame = ImMenu.EndFrame() -- This call is valid as params are optional
	local window = WindowStack:pop()

	-- Update the window size
	window.W = frame.W
	window.H = frame.H

	-- Draw late draw list (now layers)
	ImMenu.DrawLayers()

	return window
end

-- Adds a function to be drawn on a specific layer
---@param layer ImLayer|number
---@param func function
function ImMenu.DrawOnLayer(layer, func)
	if not DrawLayers[layer] then
		DrawLayers[layer] = {}
	end
	table.insert(DrawLayers[layer], func)
end

-- Flag to track if we just closed a popup and should process the click again
local justClosedPopup = false
local lastMousePos = { 0, 0 }

local function ExecutePopupContent(x, y, func)
	inPopup = true
	local currentCursorX, currentCursorY = ImMenu.Cursor.X, ImMenu.Cursor.Y -- Save cursor

	-- Prepare cursor for popup
	ImMenu.Cursor.X = math.floor(x)
	ImMenu.Cursor.Y = math.floor(y)

	-- Draw the popup
	ImMenu.PushStyle("FramePadding", 0)
	ImMenu.PushStyle("ItemMargin", 0)
	ImMenu.BeginFrame()
	func() -- Execute the user's popup content function
	local frame = ImMenu.EndFrame()
	ImMenu.PopStyle(2)

	local mousePos = input.GetMousePos()
	local mouseInsidePopup = false
	if mousePos then
		lastMousePos = mousePos -- Save for click-through
		local mouseX, mouseY = mousePos[1], mousePos[2]
		mouseInsidePopup = (
			mouseX >= frame.X
			and mouseX <= frame.X + frame.W
			and mouseY >= frame.Y
			and mouseY <= frame.Y + frame.H
		)
	end

	-- Close popup on click outside or Escape key, but allow the click to be processed by other elements
	if MouseHelper:Released() and not mouseInsidePopup then
		local currentPopup = ImMenu.ActivePopup
		ImMenu.ActivePopup = nil
		justClosedPopup = true -- Set flag so click can be processed by elements underneath
	elseif input.IsButtonPressed(KEY_ESCAPE) then
		ImMenu.ActivePopup = nil
	end

	inPopup = false
	ImMenu.Cursor.X, ImMenu.Cursor.Y = currentCursorX, currentCursorY -- Restore cursor
end

-- Process any pending click after popup is closed
function ImMenu.ProcessClickAfterPopupClose()
	if justClosedPopup and lastMousePos then
		justClosedPopup = false
		-- Reset MouseHelper's state to simulate a fresh click
		MouseHelper._LastState = false
		return true
	end
	return false
end

---@param x integer
---@param y integer
---@param func function
function ImMenu.Popup(x, y, func)
	-- Wrapper to pass arguments to the named helper
	local popupWrapper = function()
		ExecutePopupContent(x, y, func)
	end
	ImMenu.DrawOnLayer(ImLayer.Popup, popupWrapper) -- Use layer system
end

-- Draw a label
function ImMenu.Text(text)
	local x, y = math.floor(ImMenu.Cursor.X), math.floor(ImMenu.Cursor.Y)
	local label = ImMenu.GetLabel(text)
	local txtWidth, txtHeight = draw.GetTextSize(label)
	local width, height = ImMenu.GetSize(txtWidth, txtHeight)
	width, height = math.floor(width), math.floor(height) -- Ensure size is integer

	if type(Colors.Text) == "table" then
		draw.Color(UnpackColor(Colors.Text))
	end
	draw.Text(math.floor(x + (width - txtWidth) / 2), math.floor(y + (height - txtHeight) / 2), label)

	ImMenu.UpdateCursor(width, height)
end

---@param text string
---@param state boolean
---@return boolean state, boolean clicked
function ImMenu.Checkbox(text, state)
	local x, y = math.floor(ImMenu.Cursor.X), math.floor(ImMenu.Cursor.Y)
	local label = ImMenu.GetLabel(text)
	local txtWidth, txtHeight = draw.GetTextSize(label)
	local boxSize = math.floor(txtHeight + (Style.ItemPadding or 5) * 2)
	local width, height = ImMenu.GetSize(boxSize + (Style.ItemMargin or 5) + txtWidth, boxSize)
	width, height = math.floor(width), math.floor(height)
	local ix, iy = math.floor(x), math.floor(y)
	local hovered, clicked, active = ImMenu.GetInteraction(ix, iy, width, height, text)

	-- Box
	ImMenu.InteractionColor(hovered, active)
	draw.FilledRect(ix, iy, ix + boxSize, iy + boxSize)

	-- Border
	if Style.CheckboxBorder and type(Colors.Border) == "table" then
		draw.Color(UnpackColor(Colors.Border))
		draw.OutlinedRect(ix, iy, ix + boxSize, iy + boxSize)
	end

	-- Check
	if state then
		if type(Colors.Highlight) == "table" then
			draw.Color(UnpackColor(Colors.Highlight))
		end
		local pad = math.floor(Style.ItemPadding or 5)
		draw.FilledRect(ix + pad, iy + pad, ix + boxSize - pad, iy + boxSize - pad)
	end

	-- Text
	if type(Colors.Text) == "table" then
		draw.Color(UnpackColor(Colors.Text))
	end
	draw.Text(math.floor(ix + boxSize + (Style.ItemMargin or 5)), math.floor(iy + (height - txtHeight) / 2), label)

	-- Update State
	if clicked then
		state = not state
	end

	ImMenu.UpdateCursor(width, height)
	return state, clicked
end

-- Draws a button
---@param text string
---@return boolean clicked, boolean active
function ImMenu.Button(text)
	if type(text) ~= "string" then
		error("Expected 'text' to be a string, got " .. type(text))
	end

	local x, y = math.floor(ImMenu.Cursor.X), math.floor(ImMenu.Cursor.Y)
	local label = ImMenu.GetLabel(text)
	local txtWidth, txtHeight = draw.GetTextSize(label)
	local pad = Style.ItemPadding or 5
	local width, height = ImMenu.GetSize(txtWidth + pad * 2, txtHeight + pad * 2)
	width, height = math.floor(width), math.floor(height)
	local ix, iy = math.floor(x), math.floor(y)
	local hovered, clicked, active = ImMenu.GetInteraction(ix, iy, width, height, text)

	ImMenu.InteractionColor(hovered, active)
	draw.FilledRect(ix, iy, ix + width, iy + height)

	if Style.ButtonBorder and type(Colors.Border) == "table" then
		draw.Color(UnpackColor(Colors.Border))
		draw.OutlinedRect(ix, iy, ix + width, iy + height)
	end

	if type(Colors.Text) == "table" then
		draw.Color(UnpackColor(Colors.Text))
	end
	draw.Text(math.floor(ix + (width - txtWidth) / 2), math.floor(iy + (height - txtHeight) / 2), label)

	if clicked then
		ImMenu.ActiveItem = nil
	end

	ImMenu.UpdateCursor(width, height)
	return clicked, active
end

---@param id TextureID
function ImMenu.Texture(id)
	local x, y = math.floor(ImMenu.Cursor.X), math.floor(ImMenu.Cursor.Y)
	local texW, texH = draw.GetTextureSize(id)
	local width, height = ImMenu.GetSize(texW, texH)
	width, height = math.floor(width), math.floor(height)
	local ix, iy = math.floor(x), math.floor(y)

	draw.Color(255, 255, 255, 255)
	draw.TexturedRect(id, ix, iy, ix + width, iy + height)

	if Style.Border then
		draw.Color(UnpackColor(Colors.Border))
		draw.OutlinedRect(ix, iy, ix + width, iy + height)
	end

	ImMenu.UpdateCursor(width, height)
end

-- Draws a slider that changes a value with fancy visual effects and text shadow
---@param text string
---@param value number
---@param min number
---@param max number
---@param step? number
---@return number value, boolean clicked
function ImMenu.Slider(text, value, min, max, step)
	step = step or 1
	local x, y = math.floor(ImMenu.Cursor.X), math.floor(ImMenu.Cursor.Y)
	local label = string.format("%s: %.2f", ImMenu.GetLabel(text), value) -- Format value
	local txtWidth, txtHeight = draw.GetTextSize(label)
	local pad = Style.ItemPadding or 5
	local width, height = ImMenu.GetSize(250, txtHeight + pad * 2)
	width, height = math.floor(width), math.floor(height)
	local ix, iy = math.floor(x), math.floor(y)
	local sliderWidth = math.floor(width * (value - min) / (max - min))
	local hovered, clicked, active = ImMenu.GetInteraction(ix, iy, width, height, text)

	sliderWidth = math.floor(math.max(0, math.min(sliderWidth, width)))

	ImMenu.InteractionColor(hovered, active)
	draw.FilledRect(ix, iy, ix + width, iy + height)

	draw.Color(UnpackColor(Colors.Highlight))
	draw.FilledRect(ix, iy, ix + sliderWidth, iy + height)

	if Style.SliderBorder then
		draw.Color(UnpackColor(Colors.Border))
		draw.OutlinedRect(ix, iy, ix + width, iy + height)
	end

	if sliderWidth > 1 then
		draw.Color(255, 255, 255, 150)
		draw.FilledRect(ix + sliderWidth - 2, iy - 2, ix + sliderWidth + 2, iy + height + 2)
	end

	draw.Color(0, 0, 0, 150)
	draw.TextShadow(
		math.floor(ix + (width / 2) - (txtWidth / 2) + 1),
		math.floor(iy + (height / 2) - (txtHeight / 2) + 1),
		label
	)
	draw.Color(255, 255, 255, 255)
	draw.Text(math.floor(ix + (width / 2) - (txtWidth / 2)), math.floor(iy + (height / 2) - (txtHeight / 2)), label)

	if active then
		local mousePos = input.GetMousePos()
		local mX, _ = table.unpack(mousePos or { ix }) -- Provide default if nil
		mX = (type(mX) == "number" and mX) or ix -- Ensure mX is a number, default to slider x

		local percent = clamp((mX - ix) / width, 0, 1)
		value = round((min + (max - min) * percent) / step) * step
		value = math.max(min, math.min(max, value)) -- Ensure value stays within bounds
	elseif hovered then
		if LeftArrow:Pressed() then
			value = math.max(value - step, min)
		end
		if RightArrow:Pressed() then
			value = math.min(value + step, max)
		end
	end

	ImMenu.UpdateCursor(width, height)
	return value, clicked
end

-- Quadratic easing function for interpolation
local function easeInOutQuad(t)
	if t < 0.5 then
		return 2 * t * t
	else
		return -1 + (4 - 2 * t) * t
	end
end

-- Draws a progress bar with fancy visual effects
---@param value number
---@param min number
---@param max number
---@param interpolate boolean optional
function ImMenu.Progress(value, min, max, interpolate)
	interpolate = interpolate or false

	local x, y = math.floor(ImMenu.Cursor.X or 0), math.floor(ImMenu.Cursor.Y or 0)
	local width, height = ImMenu.GetSize(250, 15)

	-- Ensure width and height are integers and not nil
	width = math.floor(width or 250)
	height = math.floor(height or 15)

	-- Ensure progress value is within bounds
	value = math.max(min, math.min(max, value))
	local targetProgressWidth = math.floor(width * (value - min) / (max - min))

	-- Initialize progress tracking if needed
	if not ImMenu.ProgressState then
		ImMenu.ProgressState = {
			currentWidth = targetProgressWidth,
			lastTargetWidth = targetProgressWidth,
			lastTick = globals.TickCount(),
		}
	end

	-- Interpolation logic
	if interpolate then
		local currentTick = globals.TickCount()
		local elapsedTicks = currentTick - ImMenu.ProgressState.lastTick

		-- Adjust speed based on the distance from the target
		local distance = math.abs(targetProgressWidth - ImMenu.ProgressState.currentWidth)
		local speed = math.max(0.5, distance / 10) -- Adjust the divisor for speed control

		-- Smooth interpolation to the target value
		ImMenu.ProgressState.currentWidth = ImMenu.ProgressState.currentWidth
			+ (targetProgressWidth - ImMenu.ProgressState.currentWidth)
				* easeInOutQuad(math.min(elapsedTicks / 10, 1))

		-- Update last target width and last tick for continuous interpolation
		ImMenu.ProgressState.lastTargetWidth = targetProgressWidth
		ImMenu.ProgressState.lastTick = currentTick
	else
		ImMenu.ProgressState.currentWidth = targetProgressWidth
	end

	local progressWidth = math.floor(ImMenu.ProgressState.currentWidth)

	-- Ensure progressWidth is within bounds
	progressWidth = math.max(0, math.min(progressWidth, width))

	-- Background
	draw.Color(UnpackColor(Colors.Item))
	draw.FilledRect(x, y, x + width, y + height)

	-- Progress
	draw.Color(0, 255, 0, 255) -- Solid green color
	draw.FilledRect(x, y, x + progressWidth, y + height)

	-- Border
	if Style.Border then
		draw.Color(UnpackColor(Colors.Border))
		draw.OutlinedRect(x, y, x + width, y + height)
	end

	-- Add a thinner glow effect at the end of the progress bar
	if progressWidth > 0 then
		draw.Color(255, 255, 255, 150)
		draw.FilledRect(x + progressWidth - 1, y - 1, x + progressWidth + 1, y + height + 1)
	end

	ImMenu.UpdateCursor(width, height)
end

---@param label string
---@param text string
---@param charLimit? integer
---@return string text
function ImMenu.TextInput(label, text, charLimit)
	charLimit = charLimit or 50 -- Set default character limit to 50

	-- Initialize static variables for cursor and writing mode
	if not ImMenu.TextInputState then
		ImMenu.TextInputState = {
			cursorPos = #text,
			blinkTimer = globals.RealTime(),
			isWriting = false,
		}
	end

	local state = ImMenu.TextInputState
	local x, y = math.floor(ImMenu.Cursor.X), math.floor(ImMenu.Cursor.Y)
	local txtWidthOrig, txtHeight = draw.GetTextSize(text)
	local pad = Style.ItemPadding or 5
	local defaultWidth, defaultHeight = 250, math.floor(txtHeight + pad * 2)
	local width = math.floor(math.max(defaultWidth, txtWidthOrig + pad * 2))
	local height = defaultHeight
	local txtY = math.floor(y + (height / 2) - (txtHeight / 2))
	local ix, iy = math.floor(x), math.floor(y)
	local hovered, clicked, active = ImMenu.GetInteraction(ix, iy, width, height, label)

	-- Toggle writing mode
	if clicked then
		state.isWriting = not state.isWriting
		if state.isWriting then
			state.cursorPos = #text -- Set cursor at end when activating
		end
	elseif MouseHelper:Released() and not hovered and state.isWriting then
		state.isWriting = false
	end

	-- Adjust width dynamically
	local currentTxtWidth, _ = draw.GetTextSize(text)
	width = math.floor(math.max(defaultWidth, currentTxtWidth + pad * 2))

	-- Background
	ImMenu.InteractionColor(hovered, state.isWriting)
	draw.FilledRect(ix, iy, ix + width, iy + height)

	-- Border
	draw.Color(UnpackColor(Colors.Border))
	draw.OutlinedRect(ix, iy, ix + width, iy + height)

	-- Text rendering
	draw.Color(UnpackColor(Colors.Text))
	local displayText = text
	local cursorTextWidth = draw.GetTextSize(text:sub(1, state.cursorPos))
	local cursorX = math.floor(ix + pad + cursorTextWidth)
	draw.Text(math.floor(ix + pad), txtY, displayText)

	-- Blinking cursor
	if state.isWriting then
		local blinkPeriod = 1.0
		local shouldShowCursor = (globals.RealTime() - state.blinkTimer) % blinkPeriod < blinkPeriod / 2
		if shouldShowCursor then
			draw.Color(UnpackColor(Colors.Highlight))
			draw.FilledRect(cursorX, txtY, cursorX + 2, txtY + txtHeight)
		end
	end

	-- Text Input
	if state.isWriting then
		local key = GetInput()
		if key then
			if key == KEY_BACKSPACE then
				if state.cursorPos > 0 then
					text = text:sub(1, state.cursorPos - 1) .. text:sub(state.cursorPos + 1)
					state.cursorPos = math.max(0, state.cursorPos - 1)
				end
			elseif key == KEY_LEFT then
				state.cursorPos = math.max(0, state.cursorPos - 1)
			elseif key == KEY_RIGHT then
				state.cursorPos = math.min(#text, state.cursorPos + 1)
			elseif key == KEY_DELETE then
				if state.cursorPos < #text then
					text = text:sub(1, state.cursorPos) .. text:sub(state.cursorPos + 2)
				end
			elseif key == KEY_HOME then
				state.cursorPos = 0
			elseif key == KEY_END then
				state.cursorPos = #text
			elseif key == KEY_SPACE then
				if #text < charLimit then
					text = text:sub(1, state.cursorPos) .. " " .. text:sub(state.cursorPos + 1)
					state.cursorPos = state.cursorPos + 1
				end
			elseif key == KEY_TAB then
				if #text < charLimit then
					text = text:sub(1, state.cursorPos) .. "\t" .. text:sub(state.cursorPos + 1)
					state.cursorPos = state.cursorPos + 1
				end
			else
				local char = Input.KeyToChar(key)
				if char and #text < charLimit then
					if input.IsButtonDown(KEY_LSHIFT) then
						char = char:upper()
					else
						char = char:lower()
					end
					text = text:sub(1, state.cursorPos) .. char .. text:sub(state.cursorPos + 1)
					state.cursorPos = state.cursorPos + 1
				end
			end
			state.blinkTimer = globals.RealTime() -- Reset blink timer on input
		end
	end

	ImMenu.UpdateCursor(width, height)
	return text
end

---@param selected integer
---@param options any[]
---@return integer selected
function ImMenu.Option(selected, options)
	-- Check if the inputs are of the correct type
	if type(selected) ~= "number" then
		error("Expected a number for 'selected', got " .. type(selected))
	end
	if type(options) ~= "table" then
		error("Expected a table for 'options', got " .. type(options))
	end

	-- Handle empty options
	if #options == 0 then
		error("Options table is empty")
	end

	local _, txtHeight = draw.GetTextSize("#") -- Get text height for calculation
	local pad = Style.ItemPadding or 5
	local margin = Style.ItemMargin or 5
	local btnSize = math.floor(txtHeight + 2 * pad)
	local defaultWidth = 250
	local width, _ = ImMenu.GetSize(defaultWidth, txtHeight) -- Use default width from GetSize if available
	width = math.floor(width)

	ImMenu.PushStyle("ItemSize", { btnSize, btnSize }) -- OK: key is string, value is table
	ImMenu.PushStyle("FramePadding", 0) -- OK: key is string, value is number
	ImMenu.BeginFrame(ImAlign.Horizontal) -- OK: Has arguments

	if ImMenu.Button("<###prev") then
		selected = ((selected - 2 + #options) % #options) + 1
	end -- Fixed modulo for lua

	ImMenu.PushStyle("ItemSize", { width - (2 * btnSize) - (2 * margin), btnSize }) -- OK: key is string, value is table
	ImMenu.Text(tostring(options[selected] or "Invalid"))
	ImMenu.PopStyle()

	if ImMenu.Button(">###next") then
		selected = (selected % #options) + 1
	end

	ImMenu.EndFrame()
	ImMenu.PopStyle(2)

	return selected
end

---@param text string
---@param items string[]
function ImMenu.List(text, items)
	local _, txtHeight = draw.GetTextSize(text)
	local pad = Style.ItemPadding or 5
	local width, height = ImMenu.GetSize(250, txtHeight + pad * 2)
	width, height = math.floor(width), math.floor(height)

	ImMenu.PushStyle("FramePadding", 0) -- OK
	ImMenu.PushStyle("ItemSize", { width, height }) -- OK
	---@diagnostic disable-next-line: missing-parameter -- Add disable for linter error
	ImMenu.BeginFrame() -- OK
	ImMenu.Text(text)
	for _, item in ipairs(items) do
		ImMenu.Button(tostring(item))
	end
	---@diagnostic disable-next-line: missing-parameter
	ImMenu.EndFrame() -- OK
	ImMenu.PopStyle(2) -- Pop FramePadding and ItemSize
end

---@param text string
---@param selected table
---@param options string[]
---@return table selected
function ImMenu.Combo(text, selected, options)
	if not selected then
		selected = {}
	end

	local _, txtHeight = draw.GetTextSize(text)
	local pad = Style.ItemPadding or 5
	local width, height = ImMenu.GetSize(250, txtHeight + pad * 2)
	width, height = math.floor(width), math.floor(height)

	ImMenu.PushStyle("ItemSize", { width, height })
	if ImMenu.Button(text) then
		if ImMenu.ActivePopup == text then
			ImMenu.ActivePopup = nil
		else
			ImMenu.ActivePopup = text
		end
	end

	if ImMenu.ActivePopup == text then
		local px, py = math.floor(ImMenu.Cursor.X), math.floor(ImMenu.Cursor.Y + height)
		local popupFunc = function()
			ImMenu.PushStyle("ItemSize", { width, height })
			for i, option in ipairs(options) do
				local isSelected = selected[i] or false

				if isSelected then
					ImMenu.PushColor("Item", Colors.ItemActive)
				else
					ImMenu.PushColor("Item", Colors.Item)
				end

				local optionClicked = ImMenu.Button(tostring(option))
				if optionClicked then
					selected[i] = not selected[i]
				end

				ImMenu.PopColor()
			end
			ImMenu.PopStyle(1)
		end
		ImMenu.Popup(px, py, popupFunc)
	end

	ImMenu.PopStyle()

	return selected
end

---@param tabs table<string, boolean>|table<number, string>
---@param currentTab string
---@return string currentTab
function ImMenu.TabControl(tabs, currentTab)
	if type(tabs) ~= "table" then
		error("Expected 'tabs' to be a table, got " .. type(tabs))
	end
	if type(currentTab) ~= "string" then
		error("Expected 'currentTab' to be a string, got " .. type(currentTab))
	end

	ImMenu.PushStyle("FramePadding", 5) -- OK
	ImMenu.PushStyle("ItemSize", { 100, 25 }) -- OK
	ImMenu.PushStyle("Spacing", { 5, 5 }) -- OK
	ImMenu.BeginFrame(ImAlign.Horizontal) -- OK: Has arguments

	local tempCurrentTab = currentTab -- Avoid modifying loop variable directly
	local handler = function(tabName)
		if ImMenu.Button(tabName) then
			tempCurrentTab = tabName
		end
	end

	if #tabs > 0 then
		for _, tabName in ipairs(tabs) do
			handler(tabName)
		end
	else
		for tabName, _ in pairs(tabs) do
			handler(tabName)
		end
	end

	ImMenu.EndFrame()
	ImMenu.PopStyle(3)

	return tempCurrentTab
end

local function GetPressedkeyAndMouse()
	local pressedKey = Input.GetPressedKey()
	if not pressedKey then
		-- Check for standard mouse buttons
		if input.IsButtonDown(MOUSE_LEFT) then
			return MOUSE_LEFT
		end
		if input.IsButtonDown(MOUSE_RIGHT) then
			return MOUSE_RIGHT
		end
		if input.IsButtonDown(MOUSE_MIDDLE) then
			return MOUSE_MIDDLE
		end

		-- Check for additional mouse buttons
		for i = 1, 10 do
			if input.IsButtonDown(MOUSE_FIRST + i - 1) then
				return MOUSE_FIRST + i - 1
			end
		end
	end
	return pressedKey
end

local bindTimers = {}
local bindDelays = {}
local keybindStates = {}
local keybindModes = {}
local keybindActiveStates = {}
local keybindModeSelection = {}

---@param text string
function ImMenu.GetKeybind(text)
	local mode = keybindModes[text]
	local keybind = keybindStates[text] and GetPressedkeyAndMouse() or 0

	if mode == "Always On" then
		return true
	elseif mode == "Always Off" then
		return false
	elseif mode == "Press to Toggle" then
		if input.IsButtonDown(keybind) and not bindTimers[text .. "_Toggle"] then
			keybindActiveStates[text] = not keybindActiveStates[text]
			bindTimers[text .. "_Toggle"] = os.clock() + 0.25
		end
		if bindTimers[text .. "_Toggle"] and os.clock() > bindTimers[text .. "_Toggle"] then
			bindTimers[text .. "_Toggle"] = nil
		end
		return keybindActiveStates[text]
	elseif mode == "Hold to Use" then
		return input.IsButtonDown(keybind)
	end

	return false
end

---@param text string
function ImMenu.Keybind(text)
	local x, y = math.floor(ImMenu.Cursor.X), math.floor(ImMenu.Cursor.Y)
	local defaultWidth = 250
	local _, height = ImMenu.GetSize(0, 25) -- Get height only
	height = math.floor(height)

	-- Initialize state for this keybind
	if not bindTimers[text] then
		bindTimers[text] = 0
		bindDelays[text] = 0.25 -- Delay of 0.25 seconds
		keybindStates[text] = "Always On"
		keybindModes[text] = "Always On"
		keybindActiveStates[text] = true
		keybindModeSelection[text] = false
	end

	-- Determine the label based on the current state
	local displayLabel = keybindStates[text]
	if keybindStates[text] == "Press The Key" then
		displayLabel = "Press the key"
	end

	local label = text .. ": " .. displayLabel .. " (" .. keybindModes[text] .. ")"
	local txtWidth, txtHeight = draw.GetTextSize(label)
	local width = math.max(defaultWidth, txtWidth + Style.ItemPadding * 2)
	local ix, iy = math.floor(x), math.floor(y)
	local hovered, clicked, active = ImMenu.GetInteraction(ix, iy, width, height, text)

	-- Background
	ImMenu.InteractionColor(hovered, active)
	draw.FilledRect(ix, iy, ix + width, iy + height)

	-- Border
	if Style.ButtonBorder then
		draw.Color(UnpackColor(Colors.Highlight))
		draw.OutlinedRect(ix, iy, ix + width, iy + height)
	end

	-- Handle key binding process
	if keybindStates[text] ~= "Press The Key" and clicked then
		bindTimers[text] = os.clock() + bindDelays[text]
		keybindStates[text] = "Press The Key"
	end

	if keybindStates[text] == "Press The Key" then
		if os.clock() >= bindTimers[text] then
			local pressedKey = GetPressedkeyAndMouse()
			if pressedKey then
				if pressedKey == KEY_ESCAPE then
					-- Reset keybind if the Escape key is pressed
					keybindStates[text] = "Always On"
					keybindModes[text] = "Always On"
					Notify.Simple("Keybind Success", "Bound Key: " .. keybindStates[text], 2)
				else
					-- Update keybind with the pressed key
					keybindStates[text] = Input.GetKeyName(pressedKey)
					Notify.Simple("Keybind Success", "Bound Key: " .. keybindStates[text], 2)
				end
			end
		end
	end

	-- Right-click to select mode
	if input.IsButtonPressed(MOUSE_RIGHT) and Input.MouseInBounds(ix, iy, ix + width, iy + height) then
		ImMenu.ActivePopup = text .. "_Mode"
	end

	if ImMenu.ActivePopup == text .. "_Mode" then
		local px, py = ImMenu.Cursor.X, ImMenu.Cursor.Y
		local keybindPopupFunc = function()
			if ImMenu.Button("Always On") then
				keybindModes[text] = "Always On"
				ImMenu.ActivePopup = nil
			end
			if ImMenu.Button("Always Off") then
				keybindModes[text] = "Always Off"
				ImMenu.ActivePopup = nil
			end
			if ImMenu.Button("Press to Toggle") then
				keybindModes[text] = "Press to Toggle"
				ImMenu.ActivePopup = nil
			end
			if ImMenu.Button("Hold to Use") then
				keybindModes[text] = "Hold to Use"
				ImMenu.ActivePopup = nil
			end
		end
		ImMenu.Popup(px + width + 1, py, keybindPopupFunc)
	end

	-- Display the current keybind name and mode
	label = text .. ": " .. displayLabel .. " (" .. keybindModes[text] .. ")"
	txtWidth, txtHeight = draw.GetTextSize(label)
	draw.Color(UnpackColor(Colors.Text))
	draw.Text(math.floor(ix + (width / 2) - (txtWidth / 2)), math.floor(iy + (height / 2) - (txtHeight / 2)), label)

	ImMenu.UpdateCursor(width, height)
end

---@param text string
---@param selected integer
---@param options string[]
---@return integer selected
function ImMenu.Dropdown(text, selected, options)
	if type(selected) ~= "number" then
		LogError("Expected 'selected' to be a number, got " .. type(selected))
		return selected
	end
	if type(options) ~= "table" then
		LogError("Expected 'options' to be a table, got " .. type(options))
		return selected
	end
	if #options == 0 then
		LogError("Options table is empty")
		return selected
	end

	local x, y = math.floor(ImMenu.Cursor.X), math.floor(ImMenu.Cursor.Y)
	local label = string.format("%s: %s", ImMenu.GetLabel(text), options[selected] or "Invalid")
	local txtWidth, txtHeight = draw.GetTextSize(label)
	local pad = Style.ItemPadding or 5
	local width, height = ImMenu.GetSize(250, txtHeight + pad * 2)
	width, height = math.floor(width), math.floor(height)
	local ix, iy = math.floor(x), math.floor(y)
	local hovered, clicked, active = ImMenu.GetInteraction(ix, iy, width, height, text)

	-- Background
	ImMenu.InteractionColor(hovered, active)
	draw.FilledRect(ix, iy, ix + width, iy + height)

	-- Border
	if Style.ButtonBorder then
		draw.Color(UnpackColor(Colors.Border))
		draw.OutlinedRect(ix, iy, ix + width, iy + height)
	end

	-- Dropdown arrow
	draw.Color(UnpackColor(Colors.Text))
	local arrowSize = math.floor(height / 3)
	local arrowX = math.floor(ix + width - arrowSize - pad)
	local arrowY = math.floor(iy + (height - arrowSize) / 2)
	draw.FilledRect(arrowX, arrowY, arrowX + arrowSize, arrowY + 2)
	draw.Line(arrowX, arrowY + 2, arrowX + arrowSize / 2, arrowY + arrowSize)
	draw.Line(arrowX + arrowSize, arrowY + 2, arrowX + arrowSize / 2, arrowY + arrowSize)

	-- Text
	draw.Color(UnpackColor(Colors.Text))
	draw.Text(math.floor(ix + pad), math.floor(iy + (height - txtHeight) / 2), label)

	-- Handle dropdown popup activation with toggle
	if clicked then
		if ImMenu.ActivePopup == text then
			ImMenu.ActivePopup = nil
		else
			ImMenu.ActivePopup = text
		end
	end

	if ImMenu.ActivePopup == text then
		local px, py = math.floor(x), math.floor(y + height)
		local popupFunc = function()
			ImMenu.PushStyle("ItemSize", { width, height })
			for i, option in ipairs(options) do
				local isSelected = (i == selected)
				if isSelected then
					ImMenu.PushColor("Item", Colors.ItemActive)
				end

				local optionClicked = ImMenu.Button(tostring(option))
				if optionClicked then
					selected = i
					ImMenu.ActivePopup = nil
				end

				if isSelected then
					ImMenu.PopColor()
				end
			end
			ImMenu.PopStyle()
		end

		ImMenu.Popup(px, py, popupFunc)
	end

	ImMenu.UpdateCursor(width, height)
	return selected
end

-- Add a global function to force-close any active popup
function ImMenu.CloseActivePopup()
	if ImMenu.ActivePopup then
		ImMenu.ActivePopup = nil
	end
end

common.Lib.UI.Notify.Simple("ImMenu loaded", string.format("Version: %.2f", ImMenu.GetVersion()))

return ImMenu
