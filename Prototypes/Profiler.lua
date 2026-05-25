local __bundle_require, __bundle_loaded, __bundle_register, __bundle_modules = (function(superRequire)
	local loadingPlaceholder = { [{}] = true }

	local register
	local modules = {}

	local require
	local loaded = {}

	register = function(name, body)
		if not modules[name] then
			modules[name] = body
		end
	end

	require = function(name)
		local loadedModule = loaded[name]

		if loadedModule then
			if loadedModule == loadingPlaceholder then
				return nil
			end
		else
			if not modules[name] then
				if not superRequire then
					local identifier = type(name) == 'string' and '\"' .. name .. '\"' or tostring(name)
					error('Tried to require ' .. identifier .. ', but no such module has been registered')
				else
					return superRequire(name)
				end
			end

			loaded[name] = loadingPlaceholder
			loadedModule = modules[name](require, loaded, register, modules)
			loaded[name] = loadedModule
		end

		return loadedModule
	end

	return require, loaded, register, modules
end)(require)
__bundle_register("__root", function(require, _LOADED, __bundle_register, __bundle_modules)
	--[[
    Profiler Library - Main Entry Point
    Author: titaniummachine1

    A lightweight performance profiler for Lua applications

    Usage:
        local Profiler = require("Profiler")

        -- Control visibility
        Profiler.SetVisible(true)

        -- Measure performance
        Profiler.StartSystem("system_name")
            Profiler.StartComponent("component_name")
            -- ... your code ...
            Profiler.EndComponent("component_name")
        Profiler.EndSystem("system_name")

        -- In draw callback
        Profiler.Draw()
]]

	-- Global shared table (from Shared.lua) – retained mode
	local Shared = require("Profiler.Shared")

	-- RELOAD DETECTION: Check if profiler is already loaded
	if Shared.ProfilerInstance and Shared.ProfilerLoaded then
		print("🔄 Microprofiler already loaded - performing full reload...")

		-- Unload existing instance completely
		if Shared.ProfilerInstance.Unload then
			Shared.ProfilerInstance.Unload()
		end

		-- Force clear all package cache (improved pattern)
		local packagesToClear = {
			"Profiler",
			"Profiler.profiler",
			"Profiler.microprofiler",
			"Profiler.ui_top",
			"Profiler.ui_body",
			"Profiler.Shared",
			"Profiler.config",
			"Profiler.Main",
			"Profiler.timing",
			"Profiler.ui_warning",
		}

		for _, pkg in ipairs(packagesToClear) do
			if package.loaded[pkg] then
				package.loaded[pkg] = nil
			end
		end

		-- Clear global state
		Shared.ProfilerInstance = nil
		Shared.ProfilerLoaded = false

		-- Re-require Shared to get fresh state
		Shared = require("Profiler.Shared")

		print("📦 All packages cleared - loading fresh profiler...")
	end

	-- Check if an older version of the profiler is already loaded and unload it
	local previouslyLoaded = package.loaded["Profiler"]
	if previouslyLoaded and previouslyLoaded.Unload then
		previouslyLoaded.Unload()
	end

	-- Initialize profiler state flags (now in retained globals)
	ProfilerLoaded = false           -- Global variable (not local)
	ProfilerCallbacksRegistered = false -- Global variable
	ProfilerEnabled = false          -- Global variable

	-- Import core module (does **not** register callbacks on its own)
	local ProfilerCore = require("Profiler.profiler")
	ProfilerCore.Init()

	-- Public API table
	local Profiler = {}

	-- Re-export core functions (original API)
	Profiler.SetVisible = ProfilerCore.SetVisible
	Profiler.StartSystem = ProfilerCore.StartSystem
	Profiler.StartComponent = ProfilerCore.StartComponent
	Profiler.EndComponent = ProfilerCore.EndComponent
	Profiler.EndSystem = ProfilerCore.EndSystem
	Profiler.Draw = ProfilerCore.Draw

	-- New minimalist API for nested scopes
	Profiler.Start = ProfilerCore.Start
	Profiler.Finish = ProfilerCore.Finish
	Profiler.TogglePause = ProfilerCore.TogglePause
	Profiler.IsPaused = ProfilerCore.IsPaused
	Profiler.ToggleVisibility = ProfilerCore.ToggleVisibility

	-- Simplified API - explicit systems, Begin for components
	Profiler.BeginSystem = ProfilerCore.BeginSystem
	Profiler.EndSystem = ProfilerCore.StopSystem -- No parameters needed
	Profiler.Begin = ProfilerCore.Begin       -- Always for components
	Profiler.End = ProfilerCore.End           -- Always for components

	-- Config helpers
	Profiler.SetSortMode = ProfilerCore.SetSortMode
	Profiler.SetWindowSize = ProfilerCore.SetWindowSize
	Profiler.SetSmoothingSpeed = ProfilerCore.SetSmoothingSpeed
	Profiler.SetSmoothingDecay = ProfilerCore.SetSmoothingDecay
	Profiler.SetTextUpdateInterval = ProfilerCore.SetTextUpdateInterval
	Profiler.SetSystemMemoryMode = ProfilerCore.SetSystemMemoryMode
	Profiler.SetOverheadCompensation = ProfilerCore.SetOverheadCompensation
	Profiler.SetAutoHookEnabled = ProfilerCore.SetAutoHookEnabled
	Profiler.IsAutoHookEnabled = ProfilerCore.IsAutoHookEnabled
	Profiler.SetMeasurementMode = ProfilerCore.SetMeasurementMode
	Profiler.GetMeasurementMode = ProfilerCore.GetMeasurementMode
	Profiler.SetContext = ProfilerCore.SetContext
	Profiler.GetCurrentContext = ProfilerCore.GetCurrentContext
	Profiler.Init = ProfilerCore.Init
	Profiler.Shutdown = ProfilerCore.Shutdown
	Profiler.Reset = ProfilerCore.Reset

	-- Metadata constants (Lua 5.4 compatible)
	Profiler.VERSION = "1.0.0"
	Profiler.AUTHOR = "titaniummachine1"

	-- Convenience helpers --------------------------------------------------------
	function Profiler.Enable()
		Profiler.SetVisible(true)
		return Profiler
	end

	function Profiler.Disable()
		Profiler.SetVisible(false)
		return Profiler
	end

	function Profiler.Setup(cfg)
		cfg = cfg or {}
		if cfg.visible ~= nil then
			Profiler.SetVisible(cfg.visible)
		end
		if cfg.sortMode then
			Profiler.SetSortMode(cfg.sortMode)
		end
		if cfg.windowSize then
			Profiler.SetWindowSize(cfg.windowSize)
		end
		if cfg.smoothingSpeed then
			Profiler.SetSmoothingSpeed(cfg.smoothingSpeed)
		end
		if cfg.smoothingDecay then
			Profiler.SetSmoothingDecay(cfg.smoothingDecay)
		end
		if cfg.textUpdateInterval then
			Profiler.SetTextUpdateInterval(cfg.textUpdateInterval)
		end
		if cfg.systemMemoryMode then
			Profiler.SetSystemMemoryMode(cfg.systemMemoryMode)
		end
		if cfg.compensateOverhead ~= nil then
			Profiler.SetOverheadCompensation(cfg.compensateOverhead)
		end
		return Profiler
	end

	-- Time helper for quick instrumentation
	function Profiler.Time(systemName, componentName, func)
		if not func then
			-- Called as (componentName, func)
			func = componentName
			componentName = systemName
			systemName = "default"
		end
		Profiler.StartSystem(systemName)
		Profiler.StartComponent(componentName)
		local result = func()
		Profiler.EndComponent(componentName)
		Profiler.EndSystem(systemName)
		return result
	end

	-- Manual reload helper for development
	function Profiler.Reload()
		print("🔄 Manual reload requested...")
		Profiler.Unload()
		print("🚀 Run 'lua_load example.lua' again to get fresh profiler!")
	end

	-- Cleanup helper (enhanced for complete reloading) -------------------------
	function Profiler.Unload()
		print("🧹 Unloading Microprofiler...")

		Profiler.Shutdown()
		ProfilerCallbacksRegistered = false

		-- Reset internal state so a fresh load starts clean
		print("   ✓ Internal state reset")

		-- Clear global instance
		Shared.ProfilerInstance = nil
		Shared.ProfilerLoaded = false
		ProfilerLoaded = false
		print("   ✓ Global state cleared")

		-- Remove ALL profiler packages from cache (improved pattern)
		local packages = {
			"Profiler",
			"Profiler.profiler",
			"Profiler.microprofiler",
			"Profiler.ui_top",
			"Profiler.ui_body",
			"Profiler.Shared",
			"Profiler.config",
			"Profiler.Main",
			"Profiler.timing",
			"Profiler.ui_warning",
		}

		for _, pkg in ipairs(packages) do
			if package.loaded[pkg] then
				package.loaded[pkg] = nil
				print(string.format("   ✓ Unloaded package: %s", pkg))
			end
		end
		print("   ✓ Package cache cleared")

		print("✅ Microprofiler completely unloaded. Ready for fresh reload.")
	end

	-- Mark library as loaded (global retained mode)
	ProfilerLoaded = true
	Shared.ProfilerLoaded = true
	Shared.ProfilerInstance = Profiler

	print("🚀 Microprofiler singleton initialized!")

	-- Return shared instance (store in global for retention) --------------------
	return Profiler
end)
__bundle_register("Profiler.profiler", function(require, _LOADED, __bundle_register, __bundle_modules)
	--[[
    Core Profiler Module - Simplified Microprofiler
    Coordinates the microprofiler and UI modules
    Used by: Main.lua
]]

	-- Imports
	local Shared = require("Profiler.Shared") --[[ Imported by: Main ]]
	local config = require("Profiler.config")
	local MicroProfiler = require("Profiler.microprofiler") --[[ Imported by: profiler ]]
	local UITop = require("Profiler.ui_top") --[[ Imported by: profiler ]]
	local UIBody = require("Profiler.ui_body_simple") --[[ Imported by: profiler ]]
	local Timing = require("Profiler.timing")
	local UIWarning = require("Profiler.ui_warning")

	-- Module declaration
	local ProfilerCore = {}

	-- Local constants / utilities -------- (Lua 5.4 compatible)
	local TOP_BAR_HEIGHT = 60 -- Increased to match ui_top.lua

	-- Local variables
	local isVisible = config.visible or false
	local isInitialized = false

	-- Private helpers --------------------

	local function initialize()
		if isInitialized then
			return
		end

		-- Initialize UI modules
		UITop.Initialize()
		UIBody.Initialize()

		-- Start with body hidden (will show when paused)
		UIBody.SetVisible(false)

		isInitialized = true
	end

	local function shutdown()
		if not isInitialized and not isVisible then
			-- Even if we never initialized, make sure runtime data is cleared
			MicroProfiler.Disable()
			MicroProfiler.Reset()
			UIBody.SetVisible(false)
			Shared.ProfilerEnabled = false
			return
		end

		MicroProfiler.Disable()
		MicroProfiler.Reset()
		UIBody.SetVisible(false)
		Shared.ProfilerEnabled = false
		isVisible = false
		isInitialized = false
	end

	function ProfilerCore.Init()
		initialize()
		return ProfilerCore
	end

	function ProfilerCore.Shutdown()
		shutdown()
		package.loaded["Profiler"] = nil
		package.loaded["Profiler.profiler"] = nil
		package.loaded["Profiler.microprofiler"] = nil
		package.loaded["Profiler.ui_top"] = nil
		package.loaded["Profiler.ui_body_simple"] = nil
		package.loaded["Profiler.ui_body"] = nil
		package.loaded["Profiler.Shared"] = nil
		package.loaded["Profiler.config"] = nil
		package.loaded["Profiler.timing"] = nil
		package.loaded["Profiler.ui_warning"] = nil
	end

	-- Public API -------------------------

	function ProfilerCore.SetVisible(visible)
		if not isInitialized then
			initialize()
		end

		isVisible = visible
		Shared.ProfilerEnabled = visible

		if visible then
			-- Set RecordingStartTime when profiling starts for fixed coordinate system
			if not Shared.RecordingStartTime then
				Shared.RecordingStartTime = Timing.Now()
				print(string.format("📍 Profiler: RecordingStartTime set to %.6f", Shared.RecordingStartTime))
			end
			MicroProfiler.Enable()
		else
			MicroProfiler.Disable()
			-- Reset RecordingStartTime when profiling stops so next session starts fresh
			Shared.RecordingStartTime = nil
			UIBody.SetVisible(false)
		end
	end

	function ProfilerCore.ToggleVisibility()
		ProfilerCore.SetVisible(not isVisible)
		return isVisible
	end

	function ProfilerCore.IsVisible()
		return isVisible
	end

	-- Manual profiling API (for custom work items)
	function ProfilerCore.Begin(name, category)
		if not isVisible then
			return
		end
		-- Check if paused via UITop module
		if not isInitialized then
			initialize()
		end
		if UITop.IsPaused() then
			return -- Don't start manual profiling when paused
		end
		MicroProfiler.BeginCustomWork(name, category)
	end

	function ProfilerCore.End(name)
		if not isVisible then
			return
		end
		-- Check if paused via UITop module
		if not isInitialized then
			initialize()
		end
		if UITop.IsPaused() then
			return -- Don't end manual profiling when paused
		end
		-- If no name supplied, end the most‐recent Begin()
		if not name or name == "" then
			name = nil -- pop last
		end
		MicroProfiler.EndCustomWork(name)
	end

	-- Legacy API support (keeping for compatibility)
	function ProfilerCore.StartSystem(name)
		ProfilerCore.Begin("System: " .. name)
	end

	function ProfilerCore.EndSystem(name)
		local scopeName = "System: " .. name
		ProfilerCore.End(scopeName)
	end

	function ProfilerCore.StartComponent(name)
		ProfilerCore.Begin(name)
	end

	function ProfilerCore.EndComponent(name)
		ProfilerCore.End(name)
	end

	-- Simplified system API
	function ProfilerCore.BeginSystem(name)
		ProfilerCore.Begin("System: " .. name)
	end

	function ProfilerCore.StopSystem(name)
		local scopeName = "System: " .. name
		ProfilerCore.End(scopeName)
	end

	-- New minimalist API
	function ProfilerCore.Start(name)
		ProfilerCore.Begin(name)
	end

	function ProfilerCore.Finish(name)
		ProfilerCore.End(name)
	end

	-- Pause/Resume controls
	function ProfilerCore.TogglePause()
		if not isInitialized then
			initialize()
		end

		local wasPaused = UITop.IsPaused()
		UITop.SetPaused(not wasPaused)
		return not wasPaused
	end

	function ProfilerCore.IsPaused()
		if not isInitialized then
			return false
		end
		return UITop.IsPaused()
	end

	-- Body visibility controls
	function ProfilerCore.ToggleBody()
		if not isInitialized then
			initialize()
		end
		return UIBody.ToggleVisible()
	end

	function ProfilerCore.SetBodyVisible(visible)
		if not isInitialized then
			initialize()
		end
		UIBody.SetVisible(visible)
	end

	function ProfilerCore.IsBodyVisible()
		if not isInitialized then
			return false
		end
		return UIBody.IsVisible()
	end

	-- Config helpers (simplified)
	function ProfilerCore.SetSortMode(mode)
		config.sortMode = mode
	end

	function ProfilerCore.SetWindowSize(size)
		config.windowSize = math.max(1, math.min(300, size))
	end

	function ProfilerCore.SetSmoothingSpeed(speed)
		config.smoothingSpeed = math.max(1, math.min(50, speed))
	end

	function ProfilerCore.SetSmoothingDecay(decay)
		config.smoothingDecay = math.max(1, math.min(50, decay))
	end

	function ProfilerCore.SetTextUpdateInterval(interval)
		config.textUpdateInterval = math.max(1, interval)
	end

	function ProfilerCore.SetSystemMemoryMode(mode)
		config.systemMemoryMode = mode
	end

	function ProfilerCore.SetOverheadCompensation(enabled)
		-- Placeholder for future implementation
	end

	-- Reset profiler state
	function ProfilerCore.Reset()
		MicroProfiler.Reset()
		if isInitialized then
			UITop.Initialize()
			UIBody.Initialize()
		end
	end

	-- Main draw function
	function ProfilerCore.Draw()
		if not isVisible then
			return
		end
		if not isInitialized then
			initialize()
		end

		-- Update frame counter
		Shared.CurrentFrame = Shared.CurrentFrame + 1

		-- Check for body toggle request from UI
		if Shared.BodyToggleRequested then
			ProfilerCore.ToggleBody()
			Shared.BodyToggleRequested = false
		end

		-- Update and draw top bar
		UITop.Update()
		UITop.Draw()

		-- Draw body whenever there's data (simple system)
		if UIBody.IsVisible() then
			local profilerData = MicroProfiler.GetProfilerData()
			UIBody.Draw(profilerData, TOP_BAR_HEIGHT)
		end

		-- Draw timing server warning if needed
		UIWarning.Draw()

		-- Store last draw time
		Shared.LastDrawTime = Timing.Now()

		-- Auto-reset to tick context after drawing
		-- This allows frame context to be set just for Draw callback work
		MicroProfiler.SetContext("tick")
	end

	-- Get profiler data for external use
	function ProfilerCore.GetMainTimeline()
		return MicroProfiler.GetMainTimeline()
	end

	function ProfilerCore.GetCustomThreads()
		return MicroProfiler.GetCustomThreads()
	end

	function ProfilerCore.GetCallStack()
		return MicroProfiler.GetCallStack()
	end

	function ProfilerCore.GetProfilerData()
		return MicroProfiler.GetProfilerData()
	end

	function ProfilerCore.GetStats()
		return MicroProfiler.GetStats()
	end

	-- Debug functions
	function ProfilerCore.PrintStats()
		MicroProfiler.PrintStats()
	end

	function ProfilerCore.PrintTimeline(maxDepth)
		MicroProfiler.PrintTimeline(maxDepth)
	end

	-- Camera controls for body
	function ProfilerCore.ResetCamera()
		if not isInitialized then
			initialize()
		end
		UIBody.ResetCamera()
	end

	function ProfilerCore.SetZoom(zoom)
		if not isInitialized then
			initialize()
		end
		UIBody.SetZoom(zoom)
	end

	function ProfilerCore.GetZoom()
		if not isInitialized then
			return 1.0
		end
		return UIBody.GetZoom()
	end

	-- Measurement mode (tick vs frame)
	function ProfilerCore.SetMeasurementMode(mode)
		if mode == "tick" or mode == "frame" then
			Shared.MeasurementMode = mode
		end
	end

	function ProfilerCore.GetMeasurementMode()
		return Shared.MeasurementMode or "frame"
	end

	-- Context switching for dual tick/frame profiling
	function ProfilerCore.SetContext(contextName)
		MicroProfiler.SetContext(contextName)
	end

	function ProfilerCore.GetCurrentContext()
		return MicroProfiler.GetCurrentContext()
	end

	-- Initialize if visible by default
	if isVisible then
		initialize()
		MicroProfiler.Enable()
	end

	return ProfilerCore
end)
__bundle_register("Profiler.ui_warning", function(require, _LOADED, __bundle_register, __bundle_modules)
	local Shared = require("Profiler.Shared")

	local UIWarning = {}

	local lastCheckTime = 0
	local warningVisible = false

	function UIWarning.Draw()
		local currentTime = os.clock()

		if currentTime - lastCheckTime > 1 then
			lastCheckTime = currentTime
			warningVisible = Shared.TimingServerAvailable == false
		end

		if not warningVisible then
			return
		end

		local screenW, screenH = draw.GetScreenSize()

		local message = "⚠ Run timing_server.exe for nanosecond precision (fallback: os.clock)"
		local fontSize = 24

		local textW, textH = draw.GetTextSize(message)

		local padding = 20
		local boxW = textW + padding * 2
		local boxH = textH + padding * 2

		local boxX = (screenW - boxW) / 2
		local boxY = screenH - boxH - 20

		draw.Color(200, 50, 50, 180)
		draw.FilledRect(boxX, boxY, boxX + boxW, boxY + boxH)

		draw.Color(255, 255, 255, 255)
		draw.Text(boxX + padding, boxY + padding, message)
	end

	return UIWarning
end)
__bundle_register("Profiler.Shared", function(require, _LOADED, __bundle_register, __bundle_modules)
	--[[
    Shared Module - Shared Runtime Data (Retained Mode)
    Used by: Main.lua, profiler.lua, microprofiler.lua, ui_body.lua, ui_body_simple.lua, ui_top.lua

    This module provides shared retained state to prevent multiple instances.
    NOTE: This is NOT the external 'globals' library that provides RealTime() and FrameTime().
    That external library is safely required in each module that needs it.

    File renamed from globals.lua to Shared.lua to avoid naming conflicts.
]]

	-- Module declaration
	local Shared = {
		-- Profiler shared data
		ProfilerEnabled = false,
		CurrentFrame = 0,
		LastDrawTime = 0,
		BodyToggleRequested = false,

		-- UI State
		UITopVisible = true, -- Top bar visible by default
		UIBodyVisible = true, -- Body visible by default

		-- Measurement mode
		MeasurementMode = "frame", -- "tick" or "frame"
		RecordingStartTime = nil, -- Start time for tick counting

		-- Context separation for dual tick/frame profiling
		CurrentContext = "tick", -- "tick" or "frame"

		-- Instance control
		ProfilerInstance = nil,
		ProfilerLoaded = false,

		-- Debug settings
		DEBUG = false,

		-- Timing server status
		TimingServerAvailable = nil,
	}

	-- Return the module
	return Shared
end)
__bundle_register("Profiler.timing", function(require, _LOADED, __bundle_register, __bundle_modules)
	local Shared = require("Profiler.Shared")

	local Timing = {}

	local TIMING_SERVER = "http://127.0.0.1:9876"

	local serverAvailable = nil
	local lastFailTime = 0
	local RETRY_COOLDOWN = 5

	local function tryTimingServer(endpoint)
		local success, result = pcall(function()
			return http.Get(TIMING_SERVER .. endpoint)
		end)

		if success and result then
			local value = tonumber(result)
			if value and value >= 0 then
				if serverAvailable == false then
					Shared.TimingServerAvailable = true
					serverAvailable = true
				elseif serverAvailable == nil then
					serverAvailable = true
					Shared.TimingServerAvailable = true
				end
				return value
			end
		end

		return nil
	end

	function Timing.Now()
		if serverAvailable == false then
			local currentTime = os.clock()
			if currentTime - lastFailTime < RETRY_COOLDOWN then
				return currentTime
			end
		end

		local nanos = tryTimingServer("/now")

		if nanos then
			return nanos / 1000000000
		end

		if serverAvailable ~= false then
			serverAvailable = false
			Shared.TimingServerAvailable = false
			lastFailTime = os.clock()
		end

		return os.clock()
	end

	function Timing.IsServerAvailable()
		return serverAvailable == true
	end

	-- Smart time formatting: chooses best unit based on magnitude
	-- Input: duration in seconds
	-- Output: formatted string with appropriate unit
	function Timing.FormatDuration(durationSeconds)
		if not durationSeconds or durationSeconds ~= durationSeconds then
			return "0ns"
		end

		local ns = durationSeconds * 1000000000

		-- Choose unit based on magnitude
		if ns < 1000 then
			-- Less than 1µs: show nanoseconds
			return string.format("%.0fns", ns)
		elseif ns < 1000000 then
			-- Less than 1ms: show microseconds
			local us = ns / 1000
			if us < 10 then
				return string.format("%.2fµs", us)
			elseif us < 100 then
				return string.format("%.1fµs", us)
			else
				return string.format("%.0fµs", us)
			end
		elseif ns < 1000000000 then
			-- Less than 1s: show milliseconds
			local ms = ns / 1000000
			if ms < 10 then
				return string.format("%.3fms", ms)
			elseif ms < 100 then
				return string.format("%.2fms", ms)
			else
				return string.format("%.1fms", ms)
			end
		else
			-- 1s or more: show seconds
			local s = ns / 1000000000
			if s < 10 then
				return string.format("%.3fs", s)
			else
				return string.format("%.2fs", s)
			end
		end
	end

	return Timing
end)
__bundle_register("Profiler.ui_body_simple", function(require, _LOADED, __bundle_register, __bundle_modules)
	--[[
    Simple UI Body Module - Virtual Profiler Board
    All elements positioned on fixed coordinate system, then board is transformed
]]

	-- Imports
	local Shared = require("Profiler.Shared") --[[ Imported by: profiler ]]

	-- Module declaration
	local UIBody = {}

	-- Constants
	local BOARD_WIDTH = 2000     -- Virtual board width in pixels
	local BOARD_HEIGHT = 2000    -- Virtual board height in pixels
	local FUNCTION_HEIGHT = 20   -- Height of each function bar
	local FUNCTION_SPACING = 2   -- Spacing between function levels
	local SCRIPT_HEADER_HEIGHT = 25 -- Height of script headers
	local SCRIPT_SPACING = 10    -- Spacing between scripts
	local TIME_SCALE = 50000     -- Pixels per second (horizontal scale) - makes 1ms = 50px
	local RULER_HEIGHT = 30      -- Height of time ruler at top of body
	local MAX_TICKS = 66         -- Maximum ticks of history to display (T1-T66)
	local MEMORY_SCALE_START_MB = 1
	local MEMORY_SCALE_END_MB = 10
	local MEMORY_HEIGHT_MULTIPLIER_MAX = 2

	-- Global state (retained mode)
	local boardOffsetX = 0 -- Camera position on virtual board
	local boardOffsetY = 0 -- Camera position on virtual board
	local boardZoom = 1.0 -- Zoom level of the board
	local isDragging = false
	local lastMouseX, lastMouseY = 0, 0
	local currentTopBarHeight = 60 -- Current top bar height (updated each frame)
	local hoveredFunc = nil
	local cachedScriptKeys = {}
	local cachedScriptCount = 0
	local cachedDataStartTime = nil
	local cachedDataEndTime = nil
	local lastDataUpdateTime = 0
	local layoutItems = {}
	local levelRanges = {}
	local levelHeights = {}
	local levelOffsets = {}
	local funcCache = {}
	local globalTextSizeCache = {}
	-- Fixed-size text cache (no memory leaks, no table growth)
	-- Structure: cache[name] = { [pixelWidth] = truncatedString }
	-- We store at most MAX_TEXT_CACHE_ENTRIES function names
	local textCache = {}
	local textCacheOrder = {} -- For LRU tracking (indices 1..MAX)
	local textCacheIndex = {} -- name -> position in textCacheOrder
	local textCacheCount = 0
	local MAX_TEXT_CACHE_ENTRIES = 1000
	local nextCacheSlot = 1 -- Round-robin eviction pointer

	-- Per-frame update limit
	local maxTextUpdatesPerFrame = 50
	local updatesThisFrame = 0

	-- External APIs
	local draw_raw = draw
	local input = input
	local MOUSE_LEFT = MOUSE_LEFT or 107
	local KEY_Q = KEY_Q or 18
	local KEY_E = KEY_E or 20
	local MOUSE_WHEEL_UP = MOUSE_WHEEL_UP or 112
	local MOUSE_WHEEL_DOWN = MOUSE_WHEEL_DOWN or 113

	-- Safe coordinate validation
	local function isValidNumber(n)
		return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
	end

	local function clampCoord(n, min, max)
		if not isValidNumber(n) then
			return min or 0
		end
		if min and n < min then
			return min
		end
		if max and n > max then
			return max
		end
		return math.floor(n + 0.5)
	end

	-- Safe draw wrappers
	local draw = {}
	setmetatable(draw, {
		__index = function(t, k)
			return draw_raw[k]
		end,
	})

	function draw.FilledRect(x1, y1, x2, y2)
		x1 = clampCoord(x1, -10000, 10000)
		y1 = clampCoord(y1, -10000, 10000)
		x2 = clampCoord(x2, -10000, 10000)
		y2 = clampCoord(y2, -10000, 10000)
		return draw_raw.FilledRect(x1, y1, x2, y2)
	end

	function draw.OutlinedRect(x1, y1, x2, y2)
		x1 = clampCoord(x1, -10000, 10000)
		y1 = clampCoord(y1, -10000, 10000)
		x2 = clampCoord(x2, -10000, 10000)
		y2 = clampCoord(y2, -10000, 10000)
		return draw_raw.OutlinedRect(x1, y1, x2, y2)
	end

	function draw.Line(x1, y1, x2, y2)
		x1 = clampCoord(x1, -10000, 10000)
		y1 = clampCoord(y1, -10000, 10000)
		x2 = clampCoord(x2, -10000, 10000)
		y2 = clampCoord(y2, -10000, 10000)
		return draw_raw.Line(x1, y1, x2, y2)
	end

	function draw.Text(x, y, text)
		x = clampCoord(x, -10000, 10000)
		y = clampCoord(y, -10000, 10000)
		return draw_raw.Text(x, y, text)
	end

	function draw.Color(r, g, b, a)
		return draw_raw.Color(r, g, b, a)
	end

	function draw.GetScreenSize()
		return draw_raw.GetScreenSize()
	end

	function draw.GetTextSize(text)
		return draw_raw.GetTextSize(text)
	end

	-- globals is a global table provided by the environment (TickInterval, etc.)

	-- Helper functions
	-- Use os.clock() for microsecond-level timing precision

	-- Convert time to board X coordinate
	-- startTime is the reference for the current visible window (usually dataStartTime)
	local function timeToBoardX(time, startTime)
		return (time - startTime) * TIME_SCALE
	end

	local function clearArray(array)
		assert(array, "clearArray: array missing")
		for i = #array, 1, -1 do
			array[i] = nil
		end
	end

	local function getTextSize(text)
		assert(draw and draw.GetTextSize, "getTextSize: draw.GetTextSize missing")
		if globalTextSizeCache[text] then
			return globalTextSizeCache[text].w, globalTextSizeCache[text].h
		end
		local w, h = draw.GetTextSize(text)
		globalTextSizeCache[text] = { w = w, h = h }
		return w, h
	end

	local function getFunctionHeight(func)
		assert(func, "getFunctionHeight: func missing")
		if func._cachedHeight then
			return func._cachedHeight
		end
		local memDeltaKb = func.memDelta
		assert(type(memDeltaKb) == "number", "getFunctionHeight: memDelta invalid")
		if memDeltaKb < 0 then
			memDeltaKb = 0
		end
		local height
		if memDeltaKb < 10 then
			height = FUNCTION_HEIGHT
		else
			local logScale = math.log(memDeltaKb / 10) / math.log(10)
			local additionalHeight = logScale * 30
			height = FUNCTION_HEIGHT + additionalHeight
		end
		func._cachedHeight = height
		return height
	end

	-- Generate color: random distribution shifts from cold to warm spectrum with memory
	local function getFunctionColor(func)
		assert(func, "getFunctionColor: func missing")

		if func._cachedColor then
			return func._cachedColor.r, func._cachedColor.g, func._cachedColor.b
		end

		local memKb = func.memDelta or 0
		local memMb = memKb / 1024

		local name = func.name or "unknown"
		local hash = 0
		for i = 1, #name do
			hash = (hash * 31 + string.byte(name, i)) % 2147483647
		end

		local hueMin, hueMax
		if memMb < 0.5 then
			hueMin = 180
			hueMax = 240
		elseif memMb < 2 then
			local t = (memMb - 0.5) / 1.5
			hueMin = 180 - t * 60
			hueMax = 240 - t * 80
		elseif memMb < 5 then
			local t = (memMb - 2) / 3
			hueMin = 120 - t * 60
			hueMax = 160 - t * 100
		elseif memMb < 10 then
			local t = (memMb - 5) / 5
			hueMin = 60 - t * 40
			hueMax = 60 - t * 30
		else
			hueMin = 0
			hueMax = 15
		end

		local hueRange = hueMax - hueMin
		local hue = (hueMin + (hash % math.max(1, math.floor(hueRange)))) / 360
		local saturation = 0.55 + ((hash % 25) / 100)
		local value = 0.7 + ((hash % 20) / 100)

		local function hsvToRgb(h, s, v)
			local c = v * s
			local x = c * (1 - math.abs((h * 6) % 2 - 1))
			local m = v - c

			local rr, gg, bb
			if h < 1 / 6 then
				rr, gg, bb = c, x, 0
			elseif h < 2 / 6 then
				rr, gg, bb = x, c, 0
			elseif h < 3 / 6 then
				rr, gg, bb = 0, c, x
			elseif h < 4 / 6 then
				rr, gg, bb = 0, x, c
			elseif h < 5 / 6 then
				rr, gg, bb = x, 0, c
			else
				rr, gg, bb = c, 0, x
			end

			return (rr + m) * 255, (gg + m) * 255, (bb + m) * 255
		end

		local r, g, b = hsvToRgb(hue, saturation, value)

		r = math.floor(r + 0.5)
		g = math.floor(g + 0.5)
		b = math.floor(b + 0.5)

		func._cachedColor = { r = r, g = g, b = b }
		return r, g, b
	end

	-- Convert board coordinates to screen coordinates
	-- X is zoom-scaled, Y is NOT zoom-scaled (fixed vertical layout)
	local function boardToScreen(boardX, boardY)
		local screenX = (boardX - boardOffsetX) * boardZoom
		-- Y is in screen pixels, not board units - NO zoom scaling on Y axis
		local screenY = currentTopBarHeight + RULER_HEIGHT + boardY
		return screenX, screenY
	end

	-- Convert screen coordinates to board coordinates
	local function screenToBoard(screenX, screenY)
		local boardX = (screenX / boardZoom) + boardOffsetX
		local boardY = (screenY / boardZoom) + boardOffsetY
		return boardX, boardY
	end

	-- Get or create cached truncated text for a name at given pixel width
	-- Uses fixed-size cache with round-robin eviction
	local function getCachedTruncatedText(name, availablePixels)
		-- Quick reject: if can't fit even 1 char, return empty
		if availablePixels < 8 then
			return "", 0
		end

		-- Check if we have this name cached
		local nameCache = textCache[name]
		if not nameCache then
			-- Need to create new entry - use round-robin if at capacity
			if textCacheCount >= MAX_TEXT_CACHE_ENTRIES then
				-- Evict the oldest entry
				local evictName = textCacheOrder[nextCacheSlot]
				if evictName then
					textCache[evictName] = nil
					textCacheIndex[evictName] = nil
					textCacheCount = textCacheCount - 1
				end
			end

			-- Create new entry at current slot
			nameCache = {}
			textCache[name] = nameCache
			textCacheOrder[nextCacheSlot] = name
			textCacheIndex[name] = nextCacheSlot
			textCacheCount = textCacheCount + 1
			nextCacheSlot = nextCacheSlot + 1
			if nextCacheSlot > MAX_TEXT_CACHE_ENTRIES then
				nextCacheSlot = 1
			end
		end

		-- Check if we have this exact pixel width cached
		local cached = nameCache[availablePixels]
		if cached then
			return cached.text, cached.width
		end

		-- Need to calculate truncation
		local nameW, nameH = getTextSize(name)
		local padding = 4

		if availablePixels >= nameW + padding * 2 then
			-- Full name fits
			nameCache[availablePixels] = { text = name, width = nameW }
			return name, nameW
		end

		-- Need to truncate
		local charWidth = nameW / #name
		local maxChars = math.floor((availablePixels - padding * 2 - charWidth * 2) / charWidth)

		if maxChars <= 0 then
			-- Can't fit even truncated
			nameCache[availablePixels] = { text = "", width = 0 }
			return "", 0
		end

		local truncated = name:sub(1, maxChars) .. ".."
		local truncatedW = getTextSize(truncated)
		nameCache[availablePixels] = { text = truncated, width = truncatedW }

		return truncated, truncatedW
	end

	-- Draw a function bar on the virtual board with memory-based height scaling
	local function drawFunctionOnBoard(func, boardX, boardY, boardWidth, screenW, screenH)
		if not func.startTime or not func.endTime or not draw then
			return
		end

		-- Convert board coordinates to screen coordinates
		local screenX, screenY = boardToScreen(boardX, boardY)
		local screenWidth = boardWidth * boardZoom
		local screenHeight = getFunctionHeight(func)

		-- Clamp screen coordinates to prevent overflow at extreme zoom
		local clampLimit = math.max(100000, boardZoom * 10000)
		local clampedScreenX = math.max(-clampLimit, math.min(clampLimit, screenX))
		local clampedScreenWidth = math.max(0, math.min(clampLimit * 2, screenWidth))

		-- Only draw if visible on screen (use actual screen bounds)
		if
			clampedScreenX + clampedScreenWidth > 0
			and clampedScreenX < screenW
			and screenY + screenHeight > currentTopBarHeight
			and screenY < screenH
		then
			-- Check if mouse is hovering over this function
			local isHovered = false
			if input and input.GetMousePos then
				local pos = input.GetMousePos()
				local mx, my = pos[1] or 0, pos[2] or 0
				if
					mx >= clampedScreenX
					and mx <= clampedScreenX + clampedScreenWidth
					and my >= screenY
					and my <= screenY + screenHeight
				then
					isHovered = true
					hoveredFunc = func
				end
			end

			-- Draw function bar with fancy colors (highlight if hovered)
			local r, g, b = getFunctionColor(func)
			if isHovered then
				draw.Color(math.min(255, r + 50), math.min(255, g + 50), math.min(255, b + 50), 220)
			else
				draw.Color(r, g, b, 180)
			end
			draw.FilledRect(
				math.floor(clampedScreenX),
				math.floor(screenY),
				math.floor(clampedScreenX + clampedScreenWidth),
				math.floor(screenY + screenHeight)
			)

			-- Draw vertical grid lines on function bar (segment by milliseconds)
			local duration = func.endTime - func.startTime
			local gridInterval = 0.001 -- 1ms grid
			if duration > 0.01 then
				local gridStart = math.ceil(func.startTime / gridInterval) * gridInterval
				local gridTime = gridStart
				local gridCount = 0
				while gridTime < func.endTime and gridCount < 100 do
					local gridBoardX = timeToBoardX(gridTime, func.startTime) + boardX
					local gridScreenX, _ = boardToScreen(gridBoardX, 0)

					local clampedGridX = math.max(-clampLimit, math.min(clampLimit, gridScreenX))
					if clampedGridX >= clampedScreenX and clampedGridX <= clampedScreenX + clampedScreenWidth then
						draw.Color(255, 255, 255, 30)
						draw.Line(
							math.floor(clampedGridX),
							math.floor(screenY),
							math.floor(clampedGridX),
							math.floor(screenY + screenHeight)
						)
					end

					gridTime = gridTime + gridInterval
					gridCount = gridCount + 1
				end
			end

			-- Draw border
			draw.Color(255, 255, 255, 100)
			draw.OutlinedRect(
				math.floor(clampedScreenX),
				math.floor(screenY),
				math.floor(clampedScreenX + clampedScreenWidth),
				math.floor(screenY + screenHeight)
			)

			-- Text drawing with improved priority: name first, time on right if fits, memory below if fits
			local name = func.name or "unknown"
			if not func._dynamicText then
				local durationUs = duration * 1000000
				local durationText
				if durationUs >= 1000 then
					durationText = string.format("%.2f ms", durationUs / 1000)
				else
					durationText = string.format("%.0f µs", durationUs)
				end

				local memKb = func.memDelta or 0
				local memMb = memKb / 1024
				local memText = memMb >= 1 and string.format("%.2f MB", memMb) or string.format("%.1f KB", memKb)

				local durationW, durationH = getTextSize(durationText)
				local memW, memH = getTextSize(memText)

				func._dynamicText = {
					duration = durationText,
					memory = memText,
					durationW = durationW,
					durationH = durationH,
					memW = memW,
					memH = memH,
				}
			end
			local durationText = func._dynamicText.duration
			local memText = func._dynamicText.memory
			local durationW = func._dynamicText.durationW
			local durationH = func._dynamicText.durationH
			local memW = func._dynamicText.memW
			local memH = func._dynamicText.memH

			if draw.GetTextSize then
				local barWidthScreen = boardWidth * boardZoom
				local barHeight = getFunctionHeight(func)
				local padding = 4
				local lineSpacing = 2

				-- Use cached text lookup (no per-function cache, shared global cache)
				local displayName, actualNameW = getCachedTruncatedText(name, barWidthScreen - padding * 2)
				local _, nameH = getTextSize(name)

				if displayName ~= "" and barWidthScreen >= padding * 2 then
					local nameScreenX = screenX + padding
					local nameScreenY = screenY + 2

					if nameScreenX + actualNameW > 0 and nameScreenX < screenW then
						draw.Color(255, 255, 255, 255)
						draw.Text(math.floor(nameScreenX), math.floor(nameScreenY), displayName)
					end

					-- Only draw time if it fits without overlapping name
					local showTime = false
					local timeScreenX = screenX + barWidthScreen - durationW - padding
					if timeScreenX > nameScreenX + actualNameW + padding then
						showTime = true
					end

					if showTime and timeScreenX + durationW > 0 and timeScreenX < screenW then
						draw.Color(255, 255, 100, 255)
						draw.Text(math.floor(timeScreenX), math.floor(nameScreenY), durationText)
					end

					local showMemory = false
					if barHeight > nameH + memH + lineSpacing + 4 then
						if barWidthScreen > memW + padding * 2 then
							showMemory = true
						end
					end

					if showMemory then
						local memScreenX = screenX + padding
						local memScreenY = screenY + nameH + lineSpacing + 2

						if memScreenX + memW > 0 and memScreenX < screenW then
							draw.Color(150, 255, 150, 255)
							draw.Text(math.floor(memScreenX), math.floor(memScreenY), memText)
						end
					end
				end
			end
		end
	end

	-- Draw a script section on the virtual board
	local function drawScriptOnBoard(scriptName, functions, boardY, dataStartTime, dataEndTime, screenW, screenH)
		if not draw then
			return boardY
		end

		-- Calculate script bounds
		local scriptStartTime = math.huge
		local scriptEndTime = -math.huge

		for _, func in ipairs(functions) do
			if func.startTime and func.endTime then
				scriptStartTime = math.min(scriptStartTime, func.startTime)
				scriptEndTime = math.max(scriptEndTime, func.endTime)
			end
		end

		-- Draw script header - FIXED PIXEL HEIGHT (not zoom-scaled)
		if scriptStartTime ~= math.huge and scriptEndTime ~= -math.huge then
			local headerBoardX = timeToBoardX(scriptStartTime, dataStartTime)
			local headerBoardWidth = timeToBoardX(scriptEndTime, dataStartTime) - headerBoardX
			local headerBoardY = boardY

			-- Convert to screen coordinates
			local headerScreenX, headerScreenY = boardToScreen(headerBoardX, headerBoardY)
			local headerScreenWidth = headerBoardWidth * boardZoom
			local headerScreenHeight = SCRIPT_HEADER_HEIGHT -- Fixed pixel height, no zoom

			-- Only draw if visible (check both horizontal and vertical bounds)
			if
				headerScreenX + headerScreenWidth > 0
				and headerScreenX < screenW
				and headerScreenY + headerScreenHeight > currentTopBarHeight
				and headerScreenY < screenH
			then
				-- Draw header background (all coordinates from board transform)
				draw.Color(60, 120, 60, 200)
				draw.FilledRect(
					math.floor(headerScreenX),
					math.floor(headerScreenY),
					math.floor(headerScreenX + headerScreenWidth),
					math.floor(headerScreenY + headerScreenHeight)
				)

				-- Draw header border (all coordinates from board transform)
				draw.Color(255, 255, 255, 200)
				draw.OutlinedRect(
					math.floor(headerScreenX),
					math.floor(headerScreenY),
					math.floor(headerScreenX + headerScreenWidth),
					math.floor(headerScreenY + headerScreenHeight)
				)

				-- Draw script name (positioned on board, then transformed)
				if headerScreenHeight > 12 then
					-- Position script name on board, then transform to screen
					local nameBoardX = headerBoardX + 4
					local nameBoardY = headerBoardY + 4
					local nameScreenX, nameScreenY = boardToScreen(nameBoardX, nameBoardY)

					draw.Color(255, 255, 255, 255)
					draw.Text(math.floor(nameScreenX), math.floor(nameScreenY), scriptName)

					-- Function count (positioned on board, then transformed)
					local countText = string.format("(%d functions)", #functions)
					local countBoardX = headerBoardX + headerBoardWidth - 80
					local countBoardY = headerBoardY + 4
					local countScreenX, countScreenY = boardToScreen(countBoardX, countBoardY)

					draw.Text(math.floor(countScreenX), math.floor(countScreenY), countText)
				end
			end
		end

		boardY = boardY + SCRIPT_HEADER_HEIGHT + FUNCTION_SPACING

		local scriptCacheKey = scriptName
		if not funcCache[scriptCacheKey] then
			funcCache[scriptCacheKey] = {}
		end
		local scriptLayoutCache = funcCache[scriptCacheKey]

		local needsLayoutCalc = false
		for _, func in ipairs(functions) do
			if func._cachedLayoutY == nil then
				needsLayoutCalc = true
				break
			end
		end

		if needsLayoutCalc then
			local occupiedRegions = {}

			local function calculateLayout(func, minY)
				if not func.startTime or not func.endTime then
					return
				end

				local funcHeight = getFunctionHeight(func)
				local currentY = minY
				local foundPosition = false

				while not foundPosition do
					local collisionFound = false

					for _, region in ipairs(occupiedRegions) do
						local timeOverlap = not (func.endTime <= region.startTime or func.startTime >= region.endTime)
						local yOverlap = not (
							currentY + funcHeight + FUNCTION_SPACING <= region.y
							or currentY >= region.y + region.height + FUNCTION_SPACING
						)

						if timeOverlap and yOverlap then
							collisionFound = true
							currentY = region.y + region.height + FUNCTION_SPACING
							break
						end
					end

					if not collisionFound then
						table.insert(occupiedRegions, {
							startTime = func.startTime,
							endTime = func.endTime,
							y = currentY,
							height = funcHeight,
						})
						foundPosition = true
					end
				end

				func._cachedLayoutY = currentY

				if func.children and #func.children > 0 then
					for _, child in ipairs(func.children) do
						calculateLayout(child, currentY + funcHeight + FUNCTION_SPACING)
					end
				end
			end

			for _, func in ipairs(functions) do
				calculateLayout(func, 0)
			end

			local maxY = 0
			for _, region in ipairs(occupiedRegions) do
				maxY = math.max(maxY, region.y + region.height)
			end
			scriptLayoutCache.maxY = maxY
		end

		local function drawFunc(func)
			if not func.startTime or not func.endTime or not func._cachedLayoutY then
				return
			end

			if func.endTime < dataStartTime or func.startTime > dataEndTime then
				return
			end

			local boardX = timeToBoardX(func.startTime, dataStartTime)
			local boardWidth = timeToBoardX(func.endTime, dataStartTime) - boardX
			local currentY = func._cachedLayoutY
			local functionBoardY = boardY + currentY

			drawFunctionOnBoard(func, boardX, functionBoardY, boardWidth, screenW, screenH)

			if func.children and #func.children > 0 then
				for _, child in ipairs(func.children) do
					drawFunc(child)
				end
			end
		end

		for _, func in ipairs(functions) do
			drawFunc(func)
		end

		local maxY = scriptLayoutCache.maxY or 0
		boardY = boardY + maxY + FUNCTION_SPACING

		return boardY + SCRIPT_SPACING
	end

	-- Draw time ruler with fixed pixel spacing (works at infinite zoom)
	-- Uses actual tick boundaries from stored tick counts in profiler data
	local function drawTimeRuler(
		screenW,
		screenH,
		rulerY,
		dataStartTime,
		dataEndTime,
		tickBoundaries,
		minTick,
		maxTick,
		contextLabel
	)
		if not draw then
			return
		end

		-- Ruler background
		draw.Color(30, 30, 30, 255)
		draw.FilledRect(0, rulerY, screenW, rulerY + RULER_HEIGHT)

		-- Context label
		if contextLabel then
			draw.Color(255, 255, 100, 255)
			draw.Text(5, rulerY + 2, contextLabel)
		end

		-- Fixed pixel spacing between subdivision lines (constant on screen)
		local PIXEL_SPACING = 80

		-- Get visible time range from screen coordinates
		local visibleLeftBoardX = boardOffsetX
		local visibleRightBoardX = boardOffsetX + (screenW / boardZoom)

		-- Convert board X to time (board X is in pixels at TIME_SCALE)
		local visibleLeftTime = dataStartTime + (visibleLeftBoardX / TIME_SCALE)
		local visibleRightTime = dataStartTime + (visibleRightBoardX / TIME_SCALE)

		-- Calculate time per pixel at current zoom
		local timePerPixel = 1 / (TIME_SCALE * boardZoom)

		-- Time between each subdivision line (fixed pixel spacing)
		local timePerLine = PIXEL_SPACING * timePerPixel

		-- Fallback if no tick data
		if minTick == math.huge or not tickBoundaries then
			minTick = 0
			maxTick = MAX_TICKS
			tickBoundaries = {}
		end

		local lastLabelEndX = -1000

		-- Calculate total tick count and sliding window
		local totalTicks = maxTick - minTick + 1
		local displayStartTick = minTick

		-- If more than 66 ticks, only show the last 66
		if totalTicks > MAX_TICKS then
			displayStartTick = maxTick - MAX_TICKS + 1
		end

		-- Fallback duration if boundary missing
		local fallbackDuration = contextLabel == "FRAME" and (1.0 / 60.0) or globals.TickInterval()

		-- Build complete boundary map using actual stored durations
		local completeBoundaries = {}
		for tickNum = displayStartTick, maxTick do
			local boundary = tickBoundaries[tickNum]
			if boundary and type(boundary) == "table" and boundary.startTime then
				completeBoundaries[tickNum] = boundary
			elseif boundary and type(boundary) == "number" then
				completeBoundaries[tickNum] = {
					startTime = boundary,
					duration = fallbackDuration,
				}
			else
				local foundPrev = false
				for i = tickNum - 1, displayStartTick, -1 do
					if completeBoundaries[i] then
						local prevBoundary = completeBoundaries[i]
						local prevDuration = prevBoundary.duration or fallbackDuration
						completeBoundaries[tickNum] = {
							startTime = prevBoundary.startTime + (tickNum - i) * prevDuration,
							duration = prevDuration,
						}
						foundPrev = true
						break
					end
				end
				if not foundPrev then
					completeBoundaries[tickNum] = {
						startTime = dataStartTime + (tickNum - displayStartTick) * fallbackDuration,
						duration = fallbackDuration,
					}
				end
			end
		end

		-- Process each tick/frame in range
		for tickNum = displayStartTick, maxTick do
			local boundary = completeBoundaries[tickNum]
			if not boundary then
				goto continue_tick
			end

			local tickStartTime = boundary.startTime
			local duration = boundary.duration or fallbackDuration
			local nextBoundary = completeBoundaries[tickNum + 1]
			local tickEndTime = nextBoundary and nextBoundary.startTime or (tickStartTime + duration)

			-- Get screen positions of tick boundaries
			local tickStartBoardX = timeToBoardX(tickStartTime, dataStartTime)
			local tickEndBoardX = timeToBoardX(tickEndTime, dataStartTime)
			local tickStartScreenX = (tickStartBoardX - boardOffsetX) * boardZoom
			local tickEndScreenX = (tickEndBoardX - boardOffsetX) * boardZoom

			-- Skip if tick is completely off screen
			if tickEndScreenX < 0 or tickStartScreenX > screenW then
				goto continue_tick
			end

			-- Draw tick boundary line (stronger)
			if tickStartScreenX >= 0 and tickStartScreenX <= screenW then
				local intX = math.floor(tickStartScreenX + 0.5)
				draw.Color(150, 150, 200, 255)
				draw.Line(intX, rulerY, intX, rulerY + RULER_HEIGHT)

				-- Show relative position: T66 (oldest) to T1 (newest)
				local ticksFromNewest = maxTick - tickNum
				local relativeLabel = MAX_TICKS - ticksFromNewest
				local tickLabel = string.format("T%d", relativeLabel)
				if tickEndScreenX - tickStartScreenX >= 25 then
					draw.Color(200, 200, 255, 255)
					draw.Text(intX + 2, rulerY + 16, tickLabel)
				end
			end

			-- Draw subdivision lines within this tick at fixed pixel spacing
			-- Calculate first and last visible line indices (efficient at any zoom)
			local tickPixelWidth = tickEndScreenX - tickStartScreenX

			-- Only draw subdivisions if tick is wide enough for at least partial line
			if tickPixelWidth >= 1 then
				-- First visible line index: which line is at screen X=0 or tick start?
				local firstLineIdx, lastLineIdx
				if tickStartScreenX >= 0 then
					-- Tick starts on screen, first line is index 1
					firstLineIdx = 1
				else
					-- Tick starts off-screen left, calculate first visible line
					-- tickStartScreenX + (lineIdx * PIXEL_SPACING) >= 0
					-- lineIdx >= -tickStartScreenX / PIXEL_SPACING
					firstLineIdx = math.ceil(-tickStartScreenX / PIXEL_SPACING)
				end

				-- Last visible line index: which line is at screen X=screenW or tick end?
				-- tickStartScreenX + (lineIdx * PIXEL_SPACING) <= screenW
				-- lineIdx <= (screenW - tickStartScreenX) / PIXEL_SPACING
				lastLineIdx = math.floor((screenW - tickStartScreenX) / PIXEL_SPACING)

				-- Also cap at tick boundary (don't draw past tick end)
				local maxLineInTick = math.floor(tickPixelWidth / PIXEL_SPACING)
				lastLineIdx = math.min(lastLineIdx, maxLineInTick)

				-- Clamp to reasonable range
				firstLineIdx = math.max(1, firstLineIdx)
				lastLineIdx = math.min(lastLineIdx, 10000)

				for lineIdx = firstLineIdx, lastLineIdx do
					-- Calculate line position based on global timeline (not snapped tick)
					local timeIntoTick = lineIdx * timePerLine
					local lineAbsoluteTime = tickStartTime + timeIntoTick
					local lineBoardX = timeToBoardX(lineAbsoluteTime, dataStartTime)
					local lineScreenX = (lineBoardX - boardOffsetX) * boardZoom

					-- Safety check (should always be on screen now)
					if lineScreenX < 0 or lineScreenX > screenW then
						goto continue_line
					end

					local intX = math.floor(lineScreenX + 0.5)

					-- Subdivision line (lighter)
					draw.Color(100, 100, 100, 80)
					draw.Line(intX, rulerY, intX, rulerY + RULER_HEIGHT)

					-- Calculate time label (relative to tick start, preserving precision)
					local Timing = require("Profiler.timing")
					local label = Timing.FormatDuration(timeIntoTick)

					-- Draw label if space available (skip context label area)
					local textWidth = #label * 7 + 10
					local textX = intX + 2
					if textX >= lastLabelEndX + 10 and lineScreenX >= 80 and lineScreenX <= screenW - textWidth then
						draw.Color(150, 150, 150, 200)
						draw.Text(textX, rulerY + 15, label)
						lastLabelEndX = textX + textWidth
					end

					::continue_line::
				end
			end

			::continue_tick::
		end
	end

	-- Handle input for board navigation
	local function handleBoardInput(screenW, screenH, topBarHeight)
		if not input or not input.GetMousePos then
			return
		end

		local pos = input.GetMousePos()
		local mx, my = pos[1] or 0, pos[2] or 0

		-- Only handle input in body area
		if my < topBarHeight then
			return
		end

		local bodyMy = my - topBarHeight

		-- Handle dragging - move the board
		local currentlyDragging = input.IsButtonDown and input.IsButtonDown(MOUSE_LEFT)

		if currentlyDragging and not isDragging then
			-- Start drag
			isDragging = true
			lastMouseX = mx
			lastMouseY = bodyMy
		elseif currentlyDragging and isDragging then
			-- Continue drag - move board in opposite direction of mouse
			local deltaX = mx - lastMouseX
			local deltaY = bodyMy - lastMouseY

			-- Calculate new offset
			local newOffsetX = boardOffsetX - (deltaX / boardZoom)
			local newOffsetY = boardOffsetY - (deltaY / boardZoom)

			-- No Y scrolling - lock Y offset to 0
			newOffsetY = 0

			-- No horizontal clamping - allow moving left/right freely

			-- Apply clamped offsets
			boardOffsetX = newOffsetX
			boardOffsetY = newOffsetY

			lastMouseX = mx
			lastMouseY = bodyMy
		elseif not currentlyDragging and isDragging then
			-- End drag
			isDragging = false
		end

		-- Handle zoom with Q/E keys and scroll wheel - zoom towards mouse position
		local qPressed = input.IsButtonDown(KEY_Q)
		local ePressed = input.IsButtonDown(KEY_E)
		local scrollUp = input.IsButtonPressed(MOUSE_WHEEL_UP)
		local scrollDown = input.IsButtonPressed(MOUSE_WHEEL_DOWN)

		local zoomIn = qPressed or scrollUp
		local zoomOut = ePressed or scrollDown

		if zoomIn or zoomOut then
			local oldZoom = boardZoom

			if zoomIn then
				boardZoom = boardZoom * 1.1 -- Zoom in
			elseif zoomOut then
				boardZoom = boardZoom / 1.1 -- Zoom out
			end

			-- Clamp zoom based on RealTime precision
			-- Lua doubles have ~15-17 significant digits
			-- At 4722s, smallest delta is ~0.0001s (100μs precision)
			-- Max useful zoom: 3px = 0.0001s * TIME_SCALE * zoom
			-- zoom = 3 / (0.0001 * 50000) = 0.6 is too low
			-- Use 100μs precision -> max zoom ~1000x for 3px spacing at 100μs
			local maxZoom = 1000.0
			boardZoom = math.max(0.01, math.min(maxZoom, boardZoom))

			-- Zoom towards mouse position - keep the point under mouse cursor fixed
			-- Convert mouse screen position to board position BEFORE zoom change
			local mouseBoardX = (mx / oldZoom) + boardOffsetX
			local mouseBoardY = (bodyMy / oldZoom) + boardOffsetY

			-- No Y scrolling - lock Y offset to 0
			local newOffsetY = 0

			-- Adjust offset so the same board point stays under the mouse cursor
			local newOffsetX = mouseBoardX - (mx / boardZoom)

			-- No horizontal clamping - allow moving left/right freely

			-- Apply clamped offsets
			boardOffsetX = newOffsetX
			boardOffsetY = newOffsetY
		end
	end

	-- Get or create cached truncated text for a name at given pixel width
	-- Uses fixed-size cache with round-robin eviction
	local function getCachedTruncatedText(name, availablePixels)
		-- Quick reject: if can't fit even 1 char, return empty
		if availablePixels < 8 then
			return "", 0
		end

		-- Check if we have this name cached
		local nameCache = textCache[name]
		if not nameCache then
			-- Need to create new entry - use round-robin if at capacity
			if textCacheCount >= MAX_TEXT_CACHE_ENTRIES then
				-- Evict the oldest entry
				local evictName = textCacheOrder[nextCacheSlot]
				if evictName then
					textCache[evictName] = nil
					textCacheIndex[evictName] = nil
					textCacheCount = textCacheCount - 1
				end
			end

			-- Create new entry at current slot
			nameCache = {}
			textCache[name] = nameCache
			textCacheOrder[nextCacheSlot] = name
			textCacheIndex[name] = nextCacheSlot
			textCacheCount = textCacheCount + 1
			nextCacheSlot = nextCacheSlot + 1
			if nextCacheSlot > MAX_TEXT_CACHE_ENTRIES then
				nextCacheSlot = 1
			end
		else
			-- Move to front of LRU (optional optimization - skip for now to save CPU)
		end

		-- Check if we have this exact pixel width cached
		local cached = nameCache[availablePixels]
		if cached then
			return cached.text, cached.width
		end

		-- Need to calculate truncation
		local nameW, nameH = getTextSize(name)
		local padding = 4

		if availablePixels >= nameW + padding * 2 then
			-- Full name fits
			nameCache[availablePixels] = { text = name, width = nameW }
			return name, nameW
		end

		-- Need to truncate
		local charWidth = nameW / #name
		local maxChars = math.floor((availablePixels - padding * 2 - charWidth * 2) / charWidth)

		if maxChars <= 0 then
			-- Can't fit even truncated
			nameCache[availablePixels] = { text = "", width = 0 }
			return "", 0
		end

		local truncated = name:sub(1, maxChars) .. ".."
		local truncatedW = getTextSize(truncated)
		nameCache[availablePixels] = { text = truncated, width = truncatedW }

		return truncated, truncatedW
	end

	-- Per-frame text cache update (processes pending updates)
	local function updateTextCache()
		-- Reset per-frame counter
		updatesThisFrame = 0
	end

	-- Public API
	function UIBody.Initialize()
		boardOffsetX = 0
		boardOffsetY = 0
		boardZoom = 1.0
		isDragging = false
		print("🎨 UIBody initialized - TIME_SCALE = 50000 px/s (1ms = 50px)")
	end

	function UIBody.SetVisible(visible)
		Shared.UIBodyVisible = visible
	end

	function UIBody.IsVisible()
		return Shared.UIBodyVisible or false
	end

	function UIBody.ToggleVisible()
		local newVisibility = not (Shared.UIBodyVisible or false)
		UIBody.SetVisible(newVisibility)
		return newVisibility
	end

	function UIBody.Draw(profilerData, topBarHeight)
		if not draw or not profilerData then
			return
		end

		hoveredFunc = nil
		currentTopBarHeight = topBarHeight or 60

		local screenW, screenH = draw.GetScreenSize()

		draw.Color(20, 20, 20, 240)
		draw.FilledRect(0, topBarHeight, screenW, screenH)

		local MAX_TICKS = 66
		local tickInterval = globals.TickInterval()
		local currentTime = os.clock()

		-- Extract both contexts
		local contexts = profilerData.contexts
		if not contexts then
			return
		end

		local tickContext = contexts.TICK
		local frameContext = contexts.FRAME

		-- Helper to process a context's data
		local function processContextData(ctx)
			local minTick = math.huge
			local maxTick = -math.huge

			if ctx.scriptTimelines then
				for _, scriptData in pairs(ctx.scriptTimelines) do
					if scriptData.functions then
						for _, func in ipairs(scriptData.functions) do
							if func.startTick then
								minTick = math.min(minTick, func.startTick)
								maxTick = math.max(maxTick, func.startTick)
							end
							if func.endTick then
								maxTick = math.max(maxTick, func.endTick)
							end
						end
					end
				end
			end

			return minTick, maxTick
		end

		-- Helper to calculate time bounds for context
		local function calculateTimeBounds(ctx, minTick, maxTick)
			local validTickStart = maxTick - MAX_TICKS + 1
			if minTick == math.huge then
				validTickStart = 0
			end

			local dataStartTime = math.huge
			local dataEndTime = -math.huge
			local tickBoundaries = {}

			if ctx.callbackBoundaries then
				for tickNum, boundary in pairs(ctx.callbackBoundaries) do
					if tickNum >= validTickStart then
						local startTime, duration
						if type(boundary) == "table" and boundary.startTime then
							startTime = boundary.startTime
							duration = boundary.duration
							tickBoundaries[tickNum] = boundary
						elseif type(boundary) == "number" then
							startTime = boundary
							duration = nil
							tickBoundaries[tickNum] = { startTime = boundary, duration = nil }
						else
							goto continue_boundary
						end

						dataStartTime = math.min(dataStartTime, startTime)
						local endTime = startTime + (duration or 0)
						dataEndTime = math.max(dataEndTime, endTime)
					end
					::continue_boundary::
				end
			end

			if ctx.scriptTimelines then
				for _, scriptData in pairs(ctx.scriptTimelines) do
					if scriptData.functions then
						for _, func in ipairs(scriptData.functions) do
							local funcTick = func.startTick or func.endTick
							if funcTick and funcTick >= validTickStart then
								if func.startTime and func.endTime then
									dataStartTime = math.min(dataStartTime, func.startTime)
									dataEndTime = math.max(dataEndTime, func.endTime)

									if func.startTick and func.startTick >= validTickStart then
										if not tickBoundaries[func.startTick] then
											tickBoundaries[func.startTick] = func.startTime
										end
									end
									if func.endTick and func.endTick >= validTickStart then
										if not tickBoundaries[func.endTick] then
											tickBoundaries[func.endTick] = func.endTime
										end
									end
								end
							end
						end
					end
				end
			end

			if dataStartTime == math.huge then
				dataStartTime = currentTime - (MAX_TICKS * tickInterval)
				dataEndTime = currentTime
				minTick = globals.TickCount() - MAX_TICKS
				maxTick = globals.TickCount()
			end

			return validTickStart, dataStartTime, dataEndTime, tickBoundaries, minTick, maxTick
		end

		-- Process TICK context
		local tickMinTick, tickMaxTick = processContextData(tickContext)
		local tickValidStart, tickDataStart, tickDataEnd, tickBoundaries, tickMinTick, tickMaxTick =
			calculateTimeBounds(tickContext, tickMinTick, tickMaxTick)

		-- Process FRAME context
		local frameMinTick, frameMaxTick = processContextData(frameContext)
		local frameValidStart, frameDataStart, frameDataEnd, frameBoundaries, frameMinTick, frameMaxTick =
			calculateTimeBounds(frameContext, frameMinTick, frameMaxTick)

		-- Auto-scroll
		local UITop = require("Profiler.ui_top")
		if not UITop.IsPaused() then
			local visibleTimeWidth = screenW / (TIME_SCALE * boardZoom)
			local tickTargetOffset = (tickDataEnd - tickDataStart) - visibleTimeWidth
			if tickTargetOffset > 0 then
				boardOffsetX = tickTargetOffset * TIME_SCALE
			else
				boardOffsetX = 0
			end
		end

		-- RENDER TICK CONTEXT
		local tickRulerY = topBarHeight
		drawTimeRuler(
			screenW,
			screenH,
			tickRulerY,
			tickDataStart,
			tickDataEnd,
			tickBoundaries,
			tickMinTick,
			tickMaxTick,
			"TICK"
		)

		local tickBoardY = 0
		local tickContentBottom = tickRulerY + RULER_HEIGHT

		if tickContext.scriptTimelines then
			for scriptName, scriptData in pairs(tickContext.scriptTimelines) do
				if scriptData.functions and #scriptData.functions > 0 then
					local validFunctions = {}
					for _, func in ipairs(scriptData.functions) do
						local funcTick = func.startTick or func.endTick
						if funcTick and funcTick >= tickValidStart then
							table.insert(validFunctions, func)
						end
					end

					if #validFunctions > 0 then
						local newTickBoardY = drawScriptOnBoard(
							scriptName,
							validFunctions,
							tickBoardY,
							tickDataStart,
							tickDataEnd,
							screenW,
							screenH
						)
						-- Validate return value
						if newTickBoardY and type(newTickBoardY) == "number" and newTickBoardY == newTickBoardY then
							tickBoardY = newTickBoardY
							-- Track lowest point
							local scriptBottom = tickRulerY + RULER_HEIGHT + tickBoardY
							if scriptBottom == scriptBottom then
								tickContentBottom = math.max(tickContentBottom, scriptBottom)
							end
						end
					end
				end
			end
		end

		-- Validate tickContentBottom before using
		if tickContentBottom ~= tickContentBottom or tickContentBottom == math.huge or tickContentBottom == -math.huge then
			tickContentBottom = tickRulerY + RULER_HEIGHT
		end

		-- RENDER FRAME CONTEXT below TICK content
		local frameRulerY = tickContentBottom + 10
		drawTimeRuler(
			screenW,
			screenH,
			frameRulerY,
			frameDataStart,
			frameDataEnd,
			frameBoundaries,
			frameMinTick,
			frameMaxTick,
			"FRAME"
		)

		local frameBoardY = 0

		if frameContext.scriptTimelines then
			for scriptName, scriptData in pairs(frameContext.scriptTimelines) do
				if scriptData.functions and #scriptData.functions > 0 then
					local validFunctions = {}
					for _, func in ipairs(scriptData.functions) do
						local funcTick = func.startTick or func.endTick
						if funcTick and funcTick >= frameValidStart then
							table.insert(validFunctions, func)
						end
					end

					if #validFunctions > 0 then
						-- Temporarily adjust currentTopBarHeight for frame context
						local savedTopBar = currentTopBarHeight
						currentTopBarHeight = frameRulerY

						frameBoardY = drawScriptOnBoard(
							scriptName,
							validFunctions,
							frameBoardY,
							frameDataStart,
							frameDataEnd,
							screenW,
							screenH
						)

						currentTopBarHeight = savedTopBar
					end
				end
			end
		end

		-- Draw hover tooltip if function is hovered
		if hoveredFunc and input and input.GetMousePos then
			local pos = input.GetMousePos()
			local mx, my = pos[1] or 0, pos[2] or 0
			local tooltipX = mx + 15
			local tooltipY = my + 15
			local tooltipW = 300
			local tooltipH = 60

			if tooltipX + tooltipW > screenW then
				tooltipX = mx - tooltipW - 5
			end
			if tooltipY + tooltipH > screenH then
				tooltipY = my - tooltipH - 5
			end

			draw.Color(20, 20, 20, 240)
			draw.FilledRect(tooltipX, tooltipY, tooltipX + tooltipW, tooltipY + tooltipH)
			draw.Color(150, 200, 255, 255)
			draw.OutlinedRect(tooltipX, tooltipY, tooltipX + tooltipW, tooltipY + tooltipH)

			local textX = tooltipX + 5
			local textY = tooltipY + 5
			draw.Color(255, 255, 255, 255)
			draw.Text(textX, textY, hoveredFunc.name or "unknown")

			local startRaw = hoveredFunc.startTime
			local endRaw = hoveredFunc.endTime
			local durationSec = endRaw - startRaw

			local Timing = require("Profiler.timing")
			local durationText = "Duration: " .. Timing.FormatDuration(durationSec)

			draw.Color(255, 255, 150, 255)
			draw.Text(textX, textY + 18, durationText)

			local memKb = hoveredFunc.memDelta or 0
			local memMb = memKb / 1024
			local memText = memMb >= 1 and string.format("Memory: %.2f MB", memMb)
				or string.format("Memory: %.1f KB", memKb)
			draw.Color(150, 255, 150, 255)
			draw.Text(textX, textY + 36, memText)
		end

		-- Draw info overlay
		draw.Color(255, 255, 255, 255)
		draw.Text(10, screenH - 125, "DUAL CONTEXT MODE")
		draw.Text(10, screenH - 110, string.format("TICK: %.3fs - %.3fs", tickDataStart, tickDataEnd))
		draw.Text(10, screenH - 95, string.format("FRAME: %.3fs - %.3fs", frameDataStart, frameDataEnd))
		draw.Text(10, screenH - 80, string.format("Board Zoom: %.2fx", boardZoom))
		draw.Text(10, screenH - 65, string.format("Board Offset: X=%.0f Y=%.0f", boardOffsetX, boardOffsetY))
		draw.Text(10, screenH - 50, string.format("Time Scale: %.1f px/s", TIME_SCALE))
		draw.Text(10, screenH - 35, "Drag=Move Board, Q=Zoom In, E=Zoom Out")
		draw.Text(10, screenH - 20, string.format("Dragging: %s", tostring(isDragging)))

		-- Handle input
		handleBoardInput(screenW, screenH, topBarHeight)

		-- Process text update queue (per-frame limited updates)
		updateTextCache()
	end

	-- Camera controls
	function UIBody.ResetCamera()
		boardOffsetX = 0
		boardOffsetY = 0
		boardZoom = 1.0
	end

	function UIBody.SetZoom(newZoom)
		local maxZoom = 1000.0 -- Based on RealTime precision (~100μs)
		boardZoom = math.max(0.01, math.min(maxZoom, newZoom))
	end

	function UIBody.GetZoom()
		return boardZoom
	end

	function UIBody.CenterOnTimestamp(timestamp)
		-- Center the board on the given timestamp
		if timestamp then
			-- Calculate board X position for this timestamp
			local boardX = timestamp * TIME_SCALE
			-- Center it on screen (assuming screen width of ~1920)
			boardOffsetX = boardX - (960 / boardZoom)
		end
	end

	return UIBody
end)
__bundle_register("Profiler.ui_top", function(require, _LOADED, __bundle_register, __bundle_modules)
	--[[
    UI Top Module - Timeline and Controls
    Handles the top bar with frame timeline and control buttons
    Used by: profiler.lua
]]

	-- Imports
	local Shared = require("Profiler.Shared") --[[ Imported by: profiler ]]
	local config = require("Profiler.config")

	-- globals is a global table provided by the environment (RealTime, TickInterval, etc.)

	-- Module declaration
	local UITop = {}

	-- Local constants / utilities -------- (Lua 5.4 compatible)
	local TIMELINE_HEIGHT = 60  -- Increased height for better button fit
	local FRAME_RECORDING_TIME = 5 -- 5 seconds of frames (reduced for stability)
	local BUTTON_WIDTH = 70     -- Slightly smaller buttons
	local BUTTON_HEIGHT = 18
	local BUTTON_SPACING = 3
	local MAX_FRAMES = 150 -- Reduced frame storage

	-- Local state variables
	local frames = {}
	local selectedFrameIndex = nil
	local isPaused = false
	local isCapturingKey = false
	local bodyKey = nil
	local totalRecordedTime = 0
	local lastFrameTimestamp = 0

	-- Key constants
	local KEY_P = KEY_P or 26
	local MOUSE_LEFT = MOUSE_LEFT or 107

	-- Click/key state tracking
	local clickState = {}
	local keyState = {}

	-- Font
	local topBarFont = nil

	-- Private helpers --------------------

	-- Safe coordinate conversion for drawing API
	local function safeCoord(value)
		-- Handle NaN, infinity, and nil
		if not value or value ~= value or value == math.huge or value == -math.huge then
			return 0
		end

		-- Convert to integer and clamp to reasonable screen bounds
		local coord = math.floor(value + 0.5)
		return math.max(-10000, math.min(10000, coord))
	end

	-- Safe rectangle drawing with bounds checking
	local function safeFilledRect(x1, y1, x2, y2)
		if not draw or not draw.FilledRect then
			return
		end

		local sx1 = safeCoord(x1)
		local sy1 = safeCoord(y1)
		local sx2 = safeCoord(x2)
		local sy2 = safeCoord(y2)

		-- Ensure x1 <= x2 and y1 <= y2
		if sx1 > sx2 then
			sx1, sx2 = sx2, sx1
		end
		if sy1 > sy2 then
			sy1, sy2 = sy2, sy1
		end

		-- Only draw if dimensions are reasonable
		if (sx2 - sx1) > 0 and (sy2 - sy1) > 0 and (sx2 - sx1) < 10000 and (sy2 - sy1) < 10000 then
			draw.FilledRect(sx1, sy1, sx2, sy2)
		end
	end

	local function initializeFont()
		if not topBarFont and draw and draw.CreateFont then
			-- Create a large, crisp, readable font
			topBarFont = draw.CreateFont("Verdana", 16, 800) -- Much larger and bolder
		end
	end

	-- Remove these functions - use globals.RealTime() and globals.TickInterval() directly

	local function clamp(value, min, max)
		if value < min then
			return min
		end
		if value > max then
			return max
		end
		return value
	end

	-- Smart click handling (prevents double clicks, captures hold-to-press)
	local function consumeClick(id, hovered)
		if not input then
			return false
		end

		local currentlyDown = hovered and input.IsButtonDown and input.IsButtonDown(MOUSE_LEFT)
		local wasDown = clickState[id] or false

		-- Smart detection: capture click OR sudden hold
		if currentlyDown and not wasDown then
			-- Either clicked OR started holding (both count as press)
			clickState[id] = true
			return true
		elseif not currentlyDown and wasDown then
			-- Released - reset state for next interaction
			clickState[id] = false
		end

		return false
	end

	-- Smart key handling (prevents double presses, captures hold-to-press)
	local function consumeKeyPress(keyId)
		if not input then
			return false
		end

		local currentlyDown = input.IsButtonDown and input.IsButtonDown(keyId)
		local wasDown = keyState[keyId] or false

		-- Smart detection: capture press OR sudden hold
		if currentlyDown and not wasDown then
			-- Either pressed OR started holding (both count as press)
			keyState[keyId] = true
			return true
		elseif not currentlyDown and wasDown then
			-- Released - reset state for next interaction
			keyState[keyId] = false
		end

		return false
	end

	-- Get key name for display
	local function getKeyName(keyId)
		if keyId >= 11 and keyId <= 36 then
			return string.char(string.byte("A") + (keyId - 11))
		end
		if keyId >= 2 and keyId <= 10 then
			local d = (keyId - 1) % 10
			return tostring(d)
		end

		local names = {
			[65] = "SPACE",
			[64] = "ENTER",
			[67] = "TAB",
			[70] = "ESC",
			[79] = "LSHIFT",
			[80] = "RSHIFT",
			[83] = "LCTRL",
			[84] = "RCTRL",
			[81] = "LALT",
			[82] = "RALT",
		}

		if names[keyId] then
			return names[keyId]
		end
		if keyId >= 92 and keyId <= 103 then
			return "F" .. tostring(keyId - 91)
		end
		return tostring(keyId)
	end

	-- Update frame recording
	local function updateFrameRecording()
		if isPaused then
			return
		end

		local currentTime = os.clock()
		local tickInterval = globals.TickInterval()
		assert(tickInterval and tickInterval > 0, "updateFrameRecording: invalid tick interval")

		if currentTime - lastFrameTimestamp < tickInterval then
			return
		end

		lastFrameTimestamp = currentTime

		-- Add new frame with circular buffer approach
		if #frames >= MAX_FRAMES then
			-- Shift all frames left by one (single pass)
			totalRecordedTime = totalRecordedTime - frames[1].dt
			for i = 1, MAX_FRAMES - 1 do
				frames[i] = frames[i + 1]
			end
			frames[MAX_FRAMES] = {
				dt = tickInterval,
				timestamp = currentTime,
				index = MAX_FRAMES,
			}
			-- Adjust selected frame index
			if selectedFrameIndex then
				selectedFrameIndex = selectedFrameIndex - 1
				if selectedFrameIndex <= 0 then
					selectedFrameIndex = nil
				end
			end
		else
			frames[#frames + 1] = {
				dt = tickInterval,
				timestamp = currentTime,
				index = #frames + 1,
			}
		end

		totalRecordedTime = totalRecordedTime + tickInterval

		-- Auto-select latest frame if none selected
		if not selectedFrameIndex and #frames > 0 then
			selectedFrameIndex = #frames
		end
	end

	-- Draw frame pillars (ACTUAL PILLARS - thin and tall)
	local function drawFramePillars(screenW)
		if #frames == 0 then
			return
		end

		local maxMs = 33.3              -- ~30 FPS baseline
		local infoWidth = 100           -- Space for left side info
		local buttonSpace = BUTTON_WIDTH + 20 -- Space for right side buttons
		local frameAreaWidth = screenW - infoWidth - buttonSpace
		local frameAreaStart = infoWidth

		if frameAreaWidth <= 0 then
			return -- Not enough space
		end

		-- PILLAR SETUP: Fixed narrow width, spacing controlled
		local pillarWidth = 3 -- Thin pillars!
		local pillarSpacing = 2 -- Gap between pillars
		local totalPillarSpace = pillarWidth + pillarSpacing
		local maxPillars = math.floor(frameAreaWidth / totalPillarSpace)

		-- Only show recent frames that fit
		local startFrame = math.max(1, #frames - maxPillars + 1)
		local x = frameAreaStart

		-- Draw frames as thin pillars (newest frames from left to right)
		for i = startFrame, #frames do
			local frame = frames[i]

			-- Safe validation and calculations
			if frame and frame.dt then
				local ms = frame.dt * 1000

				-- Only proceed if ms is valid
				if ms == ms and ms ~= math.huge and ms ~= -math.huge then
					-- Height based on frame time (taller = slower frame)
					local heightNorm = clamp(ms / maxMs, 0, 1)
					if heightNorm ~= heightNorm then
						heightNorm = 0
					end
					local height = math.max(4, safeCoord(heightNorm * (TIMELINE_HEIGHT - 10)))

					-- Color based on performance (green=good, yellow=ok, red=bad)
					local r, g, b
					if heightNorm < 0.3 then
						-- Good performance - green
						r, g, b = 50, 255, 50
					elseif heightNorm < 0.7 then
						-- OK performance - yellow
						r, g, b = 255, 255, 50
					else
						-- Bad performance - red
						r, g, b = 255, 50, 50
					end

					-- Highlight selected frame
					if selectedFrameIndex == i then
						r = math.min(255, r + 50)
						g = math.min(255, g + 50)
						b = math.min(255, b + 50)
					end

					-- Draw thin pillar
					local rectX = safeCoord(x)
					local rectY = safeCoord(TIMELINE_HEIGHT - height - 2)

					if draw and height > 0 and rectX + pillarWidth < screenW - buttonSpace then
						draw.Color(r, g, b, 255)
						safeFilledRect(rectX, rectY, rectX + pillarWidth, TIMELINE_HEIGHT - 2)

						-- Store click region for interaction
						frame._clickRegion = {
							x = rectX,
							y = rectY,
							w = pillarWidth,
							h = height + 2,
						}
					end

					x = x + totalPillarSpace
				end
			end
		end
	end

	-- Draw control buttons (stacked vertically on right)
	local function drawControls(screenW)
		local buttonX = screenW - BUTTON_WIDTH - 8
		local pauseY = 4
		local bindY = pauseY + BUTTON_HEIGHT + BUTTON_SPACING

		-- Pause/Resume button
		local pauseLabel = isPaused and "Resume [P]" or "Pause [P]"

		if draw then
			-- Pause button background
			draw.Color(45, 45, 45, 255)
			safeFilledRect(buttonX, pauseY, buttonX + BUTTON_WIDTH, pauseY + BUTTON_HEIGHT)
			draw.Color(110, 110, 110, 255)
			draw.OutlinedRect(buttonX, pauseY, buttonX + BUTTON_WIDTH, pauseY + BUTTON_HEIGHT)

			-- Pause button text (integer coordinates)
			draw.Color(230, 230, 230, 255)
			draw.Text(math.floor(buttonX + 4), math.floor(pauseY + 2), pauseLabel)

			-- Keybind button background
			draw.Color(45, 45, 45, 255)
			safeFilledRect(buttonX, bindY, buttonX + BUTTON_WIDTH, bindY + BUTTON_HEIGHT)
			draw.Color(110, 110, 110, 255)
			draw.OutlinedRect(buttonX, bindY, buttonX + BUTTON_WIDTH, bindY + BUTTON_HEIGHT)

			-- Keybind button text (integer coordinates)
			local bindLabel = isCapturingKey and "Press key..." or ("Bind [" .. getKeyName(bodyKey or 25) .. "]")
			draw.Color(230, 230, 230, 255)
			draw.Text(math.floor(buttonX + 4), math.floor(bindY + 2), bindLabel)
		end

		return buttonX, pauseY, bindY
	end

	-- Handle input
	local function handleInput(screenW, buttonX, pauseY, bindY)
		if not input or not input.GetMousePos then
			return
		end

		local pos = input.GetMousePos()
		local mx, my = pos[1] or 0, pos[2] or 0

		-- Button clicks
		local hoveredPause = mx >= buttonX
			and mx <= buttonX + BUTTON_WIDTH
			and my >= pauseY
			and my <= pauseY + BUTTON_HEIGHT
		local hoveredBind = mx >= buttonX and mx <= buttonX + BUTTON_WIDTH and my >= bindY and
			my <= bindY + BUTTON_HEIGHT

		if consumeClick("pause_button", hoveredPause) then
			isPaused = not isPaused
			-- Sync pause state with microprofiler
			local MicroProfiler = require("Profiler.microprofiler")
			MicroProfiler.SetPaused(isPaused)

			-- Auto-hide body when starting recording, auto-show when pausing
			local UIBody = require("Profiler.ui_body_simple")
			if isPaused then
				UIBody.SetVisible(true)
			else
				UIBody.SetVisible(false)
			end

			return -- Don't process frame selection when clicking buttons
		end

		if consumeClick("bind_button", hoveredBind) then
			isCapturingKey = true
			return
		end

		-- Frame selection (only when paused and not clicking buttons)
		if isPaused and my >= 0 and my <= TIMELINE_HEIGHT and not hoveredPause and not hoveredBind then
			if consumeClick("frame_select", true) then
				-- Find clicked frame and center body on its time
				for i, frame in ipairs(frames) do
					if frame._clickRegion then
						local region = frame._clickRegion
						if
							mx >= region.x
							and mx <= region.x + region.w
							and my >= region.y
							and my <= region.y + region.h
						then
							selectedFrameIndex = i
							-- Center body timeline on this frame timestamp
							local UIBody = require("Profiler.ui_body")
							if UIBody and UIBody.CenterOnTimestamp then
								UIBody.CenterOnTimestamp(frame.timestamp)
							end
							break
						end
					end
				end
			end
		end
	end

	-- Handle key capture and shortcuts
	local function handleKeys()
		if not input then
			return
		end

		-- Key capture mode
		if isCapturingKey and input.IsButtonPressed then
			for keyId = 0, 113 do
				if input.IsButtonPressed(keyId) and keyId ~= MOUSE_LEFT then
					bodyKey = keyId
					isCapturingKey = false
					break
				end
			end
		end

		-- Pause shortcut
		if consumeKeyPress(KEY_P) then
			isPaused = not isPaused
			-- Sync pause state with microprofiler
			local MicroProfiler = require("Profiler.microprofiler")
			MicroProfiler.SetPaused(isPaused)

			-- Auto-hide body when starting recording, auto-show when pausing
			local UIBody = require("Profiler.ui_body_simple")
			if isPaused then
				UIBody.SetVisible(true)
			else
				UIBody.SetVisible(false)
			end
		end

		-- Body visibility shortcut
		if bodyKey and consumeKeyPress(bodyKey) then
			-- This will be handled by the main profiler
			Shared.BodyToggleRequested = true
		end
	end

	-- Public API -------------------------

	function UITop.Initialize()
		initializeFont()
		isPaused = false
		isCapturingKey = false
		bodyKey = 25 -- Default to 'O' key
		selectedFrameIndex = nil
		frames = {}
		totalRecordedTime = 0
	end

	function UITop.Update()
		updateFrameRecording()
	end

	function UITop.Draw()
		if not draw then
			return
		end

		local screenW, _ = draw.GetScreenSize()

		-- Set font
		if topBarFont and draw.SetFont then
			draw.SetFont(topBarFont)
		end

		-- Draw background
		draw.Color(18, 18, 18, 200)
		safeFilledRect(0, 0, screenW, TIMELINE_HEIGHT)
		draw.Color(70, 70, 70, 255)
		draw.OutlinedRect(0, 0, screenW, TIMELINE_HEIGHT)

		-- Draw left side info (integer coordinates for crisp text, larger font spacing)
		assert(globals and globals.TickInterval, "UITop.Draw: globals.TickInterval missing")
		local dt = globals.TickInterval()
		local fps = dt > 0 and math.floor(1 / dt + 0.5) or 0
		draw.Color(230, 230, 230, 255)
		draw.Text(8, 6, "FPS: " .. tostring(fps))

		-- Draw profiler status
		local status = isPaused and "PAUSED" or "RECORDING"
		if isPaused then
			draw.Color(255, 200, 0, 255)
		else
			draw.Color(0, 255, 0, 255)
		end
		draw.Text(8, 26, status)

		-- Draw frame count info
		draw.Color(180, 180, 180, 255)
		draw.Text(8, 46, "Frames: " .. tostring(#frames))

		-- Draw frame pillars
		drawFramePillars(screenW)

		-- Draw controls
		local buttonX, pauseY, bindY = drawControls(screenW)

		-- Handle input
		handleInput(screenW, buttonX, pauseY, bindY)
		handleKeys()

		-- Draw selected frame cursor
		if selectedFrameIndex and frames[selectedFrameIndex] and frames[selectedFrameIndex]._clickRegion then
			local region = frames[selectedFrameIndex]._clickRegion
			local cursorX = region.x + region.w / 2
			draw.Color(0, 255, 0, 255)
			safeFilledRect(cursorX - 1, 0, cursorX + 1, TIMELINE_HEIGHT)
		end
	end

	function UITop.SetPaused(paused)
		isPaused = paused
		-- Also set pause state in microprofiler
		local MicroProfiler = require("Profiler.microprofiler")
		MicroProfiler.SetPaused(paused)
	end

	function UITop.IsPaused()
		return isPaused
	end

	function UITop.GetSelectedFrame()
		if selectedFrameIndex and frames[selectedFrameIndex] then
			return frames[selectedFrameIndex]
		end
		return nil
	end

	function UITop.GetFrames()
		return frames
	end

	function UITop.SetBodyKey(keyId)
		bodyKey = keyId
	end

	function UITop.GetBodyKey()
		return bodyKey
	end

	return UITop
end)
__bundle_register("Profiler.microprofiler", function(require, _LOADED, __bundle_register, __bundle_modules)
	--[[
    Microprofiler Module - Automatic Function Hooking
    Implements automatic function profiling like Roblox microprofiler
    Used by: profiler.lua
]]

	-- Imports
	local Shared = require("Profiler.Shared") --[[ Imported by: profiler ]]
	local Timing = require("Profiler.timing")

	-- Module declaration
	local MicroProfiler = {}

	-- Local constants / utilities --------

	-- API guard to prevent recursion
	local inProfilerAPI = false
	local autoHookDesired = false

	-- Performance limits (tick-based history)
	local MAX_TICKS = 66       -- Keep max 66 ticks of history (~1 second at 66 tick rate)
	local MAX_TIMELINE_SIZE = 200 -- Functions per timeline
	local MAX_CUSTOM_THREADS = 50 -- Custom work items
	local CLEANUP_INTERVAL = 0.5 -- Cleanup frequency

	-- Context definitions
	local Contexts = {
		TICK = {
			id = "tick",
			last_id = 0,
			current_record = 1,
			callStack = {},
			mainTimeline = {},
			customThreads = {},
			activeCustomStack = {},
			scriptTimelines = {},
			callbackBoundaries = {},
		},
		FRAME = {
			id = "frame",
			last_id = 0,
			current_record = 1,
			callStack = {},
			mainTimeline = {},
			customThreads = {},
			activeCustomStack = {},
			scriptTimelines = {},
			callbackBoundaries = {},
		},
	}

	-- Local state (not global)
	local isEnabled = false
	local isHooked = false
	local isPaused = false
	local currentContext = Contexts.TICK
	local lastCleanupTime = 0

	-- External APIs (Lua 5.4 compatible)
	-- Use external globals library (RealTime, FrameTime) directly since it's globally available

	-- Private helpers --------------------

	-- Forward declaration so later calls see the local, not a global
	local autoDisableIfIdle

	local function getCurrentTime()
		return Timing.Now()
	end

	-- Auto-shift context to next record slot
	local function autoShiftContext(ctx, forceIncrement)
		assert(ctx, "autoShiftContext: ctx missing")

		if ctx.id == "tick" then
			-- Tick context uses engine tick count
			local engine_id = globals.TickCount()
			if engine_id ~= ctx.last_id then
				ctx.current_record = (ctx.current_record % MAX_TICKS) + 1
				ctx.last_id = engine_id
			end
		else
			-- Frame context increments on every SetContext call
			if forceIncrement then
				ctx.current_record = (ctx.current_record % MAX_TICKS) + 1
				ctx.last_id = (ctx.last_id or 0) + 1
			end
		end
	end

	-- Get memory usage in KB
	local function getMemory()
		return collectgarbage("count")
	end

	-- Filter array in single pass - O(n) instead of O(n^2) from repeated table.remove
	local function filterArray(arr, keepFn)
		local writeIdx = 1
		for readIdx = 1, #arr do
			if keepFn(arr[readIdx]) then
				if writeIdx ~= readIdx then
					arr[writeIdx] = arr[readIdx]
				end
				writeIdx = writeIdx + 1
			end
		end
		-- Nil out remaining slots
		for i = writeIdx, #arr do
			arr[i] = nil
		end
	end

	-- Cleanup old records for a specific context
	local function cleanupContext(ctx)
		assert(ctx, "cleanupContext: ctx missing")

		local currentTime = getCurrentTime()
		local tickInterval = globals.TickInterval()
		local maxHistoryTime = MAX_TICKS * tickInterval
		local cutoffTime = currentTime - maxHistoryTime

		filterArray(ctx.mainTimeline, function(record)
			return not record.endTime or record.endTime >= cutoffTime
		end)

		filterArray(ctx.customThreads, function(thread)
			return not thread.endTime or thread.endTime >= cutoffTime
		end)

		for scriptName, scriptData in pairs(ctx.scriptTimelines) do
			filterArray(scriptData.functions, function(func)
				return not func.endTime or func.endTime >= cutoffTime
			end)

			if #scriptData.functions == 0 then
				ctx.scriptTimelines[scriptName] = nil
			end
		end

		local boundariesToRemove = {}
		for tickNum, boundary in pairs(ctx.callbackBoundaries) do
			local boundaryTime = boundary.startTime or boundary
			if type(boundaryTime) == "number" and boundaryTime < cutoffTime then
				table.insert(boundariesToRemove, tickNum)
			end
		end
		for _, tickNum in ipairs(boundariesToRemove) do
			ctx.callbackBoundaries[tickNum] = nil
		end
	end

	-- Cleanup old records - ONLY when NOT paused to preserve navigation data
	local function cleanupOldRecords()
		if isPaused then
			return
		end

		local currentTime = getCurrentTime()

		if currentTime - lastCleanupTime < CLEANUP_INTERVAL then
			return
		end

		lastCleanupTime = currentTime

		cleanupContext(Contexts.TICK)
		cleanupContext(Contexts.FRAME)
	end

	-- Check if we should profile this function (FIXED: Not too aggressive)
	local function shouldProfile(info)
		-- Guard against profiler API recursion
		if inProfilerAPI then
			return false
		end

		if not info or not info.short_src then
			return false
		end

		-- Enhanced string matching
		local source = info.short_src
		local name = info.name or ""

		-- Skip built-in Lua functions and C functions FIRST
		if source == "=[C]" or source == "=[string]" or source == "" then
			return false
		end

		-- Skip common built-in function names that cause overhead
		if
			name == "pairs"
			or name == "ipairs"
			or name == "next"
			or name == "type"
			or name == "tostring"
			or name == "tonumber"
			or name == "getmetatable"
			or name == "setmetatable"
			or name == "rawget"
			or name == "rawset"
			or name == "pcall"
			or name == "xpcall"
			or name == "require"
			or name == "sethook"
			or name == "getinfo"
		then
			return false
		end

		-- ONLY skip actual profiler internal functions by name
		if
			name
			and (
				name:find("profileHook", 1, true)
				or name:find("shouldProfile", 1, true)
				or name:find("createFunctionRecord", 1, true)
				or name:find("cleanupOldRecords", 1, true)
				or name:find("enableHook", 1, true)
				or name:find("disableHook", 1, true)
				or name:find("testHook", 1, true)
			)
		then
			return false
		end

		-- COMPLETELY FILTER OUT "Local//Profiler" functions
		-- Use GetScriptName to determine real script
		local scriptName = "Unknown"
		if GetScriptName then
			local fullPath = GetScriptName()
			if fullPath then
				scriptName = fullPath:match("\\([^\\]-)$") or fullPath:match("/([^/]-)$") or fullPath
				if scriptName:match("%.lua$") then
					scriptName = scriptName:gsub("%.lua$", "")
				end
			end
		end

		-- STRICT FILTERING: Only allow actual user scripts, block profiler completely
		if scriptName:find("Profiler", 1, true) or scriptName == "Local" then
			return false -- Skip profiler-related scripts
		end

		-- Skip internal profiler functions by name
		if
			name
			and (
				name:find("MicroProfiler", 1, true)
				or name:find("UITop", 1, true)
				or name:find("UIBody", 1, true)
				or name:find("ProfilerCore", 1, true)
				or name:find("safeCoord", 1, true)
				or name:find("safeFilledRect", 1, true)
			)
		then
			return false
		end

		return true
	end

	-- Create function record with script separation
	local function createFunctionRecord(info)
		local name = info.name or "anonymous"

		if name ~= "anonymous" and name:find("%.") then
			name = name:match("([^%.]+)$") or name
		end

		local source = info.short_src or "unknown"
		local line = info.linedefined or 0

		-- Use lmaobox GetScriptName() with proper Windows path handling
		local scriptName = "Unknown Script"
		if GetScriptName then
			local fullPath = GetScriptName()
			if fullPath then
				-- Extract filename from Windows path and remove .lua extension for display
				scriptName = fullPath:match("\\([^\\]-)$") or fullPath:match("/([^/]-)$") or fullPath
				if scriptName:match("%.lua$") then
					scriptName = scriptName:gsub("%.lua$", "")
				end
			end
		else
			-- Fallback: Extract script name from source
			scriptName = source:match("[^/\\]+$") or source
			if scriptName == "" or scriptName == "unknown" then
				scriptName = "Unknown Script"
			end
			if scriptName:match("%.lua$") then
				scriptName = scriptName:gsub("%.lua$", "")
			end
		end

		-- Clean up bundled script names
		if scriptName == "Profiler" then
			scriptName = "example" -- User's actual script when bundled
		end

		-- Create a more readable key (Lua 5.4 enhanced)
		local key = name
		if name == "anonymous" then
			key = string.format("%s:%d", scriptName, line)
		end

		return {
			key = key,
			name = name,
			source = source,
			scriptName = scriptName,
			line = line,
			startTime = getCurrentTime(),
			startTick = globals.TickCount(),
			memStart = getMemory(),
			endTime = nil,
			endTick = nil,
			memDelta = 0,
			duration = 0,
			children = {},
		}
	end

	-- Hook function for automatic profiling (SIMPLIFIED for performance)
	local function profileHook(event)
		if not isEnabled or inProfilerAPI then
			return
		end

		if isPaused then
			return
		end

		local currentTime = getCurrentTime()
		if currentTime - lastCleanupTime > CLEANUP_INTERVAL then
			cleanupOldRecords()
			autoDisableIfIdle()
		end

		autoShiftContext(currentContext)

		local info = debug.getinfo(2, "nS")
		if not info then
			return
		end

		if not shouldProfile(info) then
			return
		end

		local ctx = currentContext
		assert(ctx, "profileHook: currentContext missing")

		if event == "call" then
			if #ctx.callStack > 20 then
				return
			end

			local record = createFunctionRecord(info)

			if #ctx.callStack > 0 then
				table.insert(ctx.callStack[#ctx.callStack].children, record)
			end

			table.insert(ctx.callStack, record)
		elseif event == "return" then
			local record = table.remove(ctx.callStack)
			if not record then
				return
			end

			record.endTime = getCurrentTime()
			record.endTick = globals.TickCount()
			record.memDelta = getMemory() - record.memStart
			record.duration = record.endTime - record.startTime

			if record.duration < 0 then
				record.duration = 0
			end

			if #ctx.callStack == 0 then
				if #ctx.mainTimeline >= MAX_TIMELINE_SIZE then
					for i = 1, MAX_TIMELINE_SIZE - 1 do
						ctx.mainTimeline[i] = ctx.mainTimeline[i + 1]
					end
					ctx.mainTimeline[MAX_TIMELINE_SIZE] = record
				else
					ctx.mainTimeline[#ctx.mainTimeline + 1] = record
				end

				local scriptName = record.scriptName
				if not ctx.scriptTimelines[scriptName] then
					ctx.scriptTimelines[scriptName] = {
						name = scriptName,
						functions = {},
						type = "script",
					}
				end

				local funcs = ctx.scriptTimelines[scriptName].functions
				if #funcs >= MAX_TIMELINE_SIZE then
					for i = 1, MAX_TIMELINE_SIZE - 1 do
						funcs[i] = funcs[i + 1]
					end
					funcs[MAX_TIMELINE_SIZE] = record
				else
					funcs[#funcs + 1] = record
				end
			end

			for _, thread in ipairs(ctx.activeCustomStack) do
				if record.startTime >= thread.startTime and (not thread.endTime or record.endTime <= thread.endTime) then
					if #thread.children < 100 then
						local copy = {
							key = record.key,
							name = record.name,
							source = record.source,
							line = record.line,
							startTime = record.startTime,
							endTime = record.endTime,
							duration = record.duration,
							memDelta = record.memDelta,
							children = record.children,
						}
						table.insert(thread.children, copy)
					end
				end
			end
		end
	end

	-- Enable automatic profiling hook
	local function enableHook()
		if not autoHookDesired or isHooked or not isEnabled then
			return
		end

		if not debug or not debug.sethook then
			print("❌ WARNING: debug.sethook is not available. Auto-hooking remains disabled; manual profiling only.")
			return
		end

		local success, err = pcall(function()
			debug.sethook(profileHook, "cr")
		end)

		if not success then
			print("❌ ERROR: Failed to set debug hook: " .. tostring(err))
			print("   Automatic profiling disabled. Manual profiling still works.")
			return
		end

		isHooked = true
		print("✅ Debug hook enabled (manual opt-in)")
	end

	-- Disable automatic profiling hook
	local function disableHook()
		if isHooked then
			debug.sethook(nil, "")
			isHooked = false
		end
	end

	-- Public API -------------------------

	function MicroProfiler.Enable()
		isEnabled = true
		if autoHookDesired then
			enableHook()
		else
			disableHook()
		end
	end

	function MicroProfiler.Disable()
		isEnabled = false
		disableHook()
	end

	-- Auto-disable when idle (no data and not paused) - to avoid lingering hooks
	function autoDisableIfIdle()
		if not isEnabled or isPaused then
			return
		end
		local hasData = false
		for _, ctx in pairs(Contexts) do
			if #ctx.mainTimeline > 0 or #ctx.customThreads > 0 then
				hasData = true
				break
			end
			for _ in pairs(ctx.scriptTimelines) do
				hasData = true
				break
			end
			if hasData then
				break
			end
		end
		if not hasData then
			disableHook()
		end
	end

	function MicroProfiler.IsEnabled()
		return isEnabled
	end

	function MicroProfiler.IsHooked()
		return isHooked
	end

	function MicroProfiler.SetAutoHookEnabled(enabled)
		autoHookDesired = not not enabled
		if not autoHookDesired then
			disableHook()
		elseif isEnabled then
			enableHook()
		end
	end

	function MicroProfiler.IsAutoHookEnabled()
		return autoHookDesired
	end

	function MicroProfiler.SetPaused(paused)
		local wasPaused = isPaused
		isPaused = paused

		if paused and not wasPaused then
			local currentTime = getCurrentTime()
			local currentMem = getMemory()
			local currentTick = globals.TickCount()

			for _, ctx in pairs(Contexts) do
				for i = #ctx.activeCustomStack, 1, -1 do
					local work = ctx.activeCustomStack[i]
					if not work.endTime then
						work.endTime = currentTime
						work.endTick = currentTick
						work.memDelta = currentMem - work.memStart
						work.duration = work.endTime - work.startTime
					end
				end

				for i = #ctx.callStack, 1, -1 do
					local record = ctx.callStack[i]
					if not record.endTime then
						record.endTime = currentTime
						record.endTick = currentTick
						record.memDelta = currentMem - record.memStart
						record.duration = record.endTime - record.startTime
					end
				end

				ctx.activeCustomStack = {}
				ctx.callStack = {}
			end
		elseif not paused and wasPaused then
			if Shared then
				Shared.RecordingStartTime = getCurrentTime()
			end
			if isEnabled and not isHooked then
				enableHook()
			end
		end
	end

	function MicroProfiler.IsPaused()
		return isPaused
	end

	-- Manual profiling for custom work items (with API guards)
	function MicroProfiler.BeginCustomWork(name, category)
		if not isEnabled or inProfilerAPI or isPaused then
			return
		end

		if not name or name == "" then
			print("BeginCustomWork: name is required")
			return
		end

		if isPaused then
			return
		end

		inProfilerAPI = true

		local scriptName = "Manual Work"
		for level = 3, 10 do
			local info = debug.getinfo(level, "S")
			if not info then
				break
			end
			local source = info.source or ""
			local fileName = source:match("\\([^\\]-)$") or source:match("/([^/]-)$") or source
			if fileName:match("%.lua$") then
				fileName = fileName:gsub("%.lua$", "")
			end
			if fileName ~= "Profiler" and fileName ~= "" and fileName ~= "[C]" and fileName ~= "[string]" then
				scriptName = fileName
				break
			end
		end

		local work = {
			name = name,
			category = category or nil,
			scriptName = scriptName,
			startTime = getCurrentTime(),
			startTick = globals.TickCount(),
			memStart = getMemory(),
			endTime = nil,
			endTick = nil,
			memDelta = 0,
			duration = 0,
			children = {},
			type = "custom",
		}

		local ctx = currentContext
		assert(ctx, "BeginCustomWork: currentContext missing")

		if #ctx.customThreads >= MAX_CUSTOM_THREADS then
			for i = 1, MAX_CUSTOM_THREADS - 1 do
				ctx.customThreads[i] = ctx.customThreads[i + 1]
			end
			ctx.customThreads[MAX_CUSTOM_THREADS] = work
		else
			ctx.customThreads[#ctx.customThreads + 1] = work
		end

		if #ctx.activeCustomStack >= 10 then
			for i = 1, 9 do
				ctx.activeCustomStack[i] = ctx.activeCustomStack[i + 1]
			end
			ctx.activeCustomStack[10] = work
		else
			ctx.activeCustomStack[#ctx.activeCustomStack + 1] = work
		end

		inProfilerAPI = false
	end

	function MicroProfiler.EndCustomWork(name)
		if not isEnabled or inProfilerAPI or isPaused then
			return
		end

		local ctx = currentContext
		assert(ctx, "EndCustomWork: currentContext missing")

		if not name or name == "" then
			if #ctx.activeCustomStack == 0 then
				inProfilerAPI = false
				return
			end
			name = ctx.activeCustomStack[#ctx.activeCustomStack].name
		end

		inProfilerAPI = true

		local work = nil
		for i = #ctx.activeCustomStack, 1, -1 do
			if ctx.activeCustomStack[i].name == name then
				work = ctx.activeCustomStack[i]
				table.remove(ctx.activeCustomStack, i)
				break
			end
		end

		if work then
			work.endTime = getCurrentTime()
			work.endTick = globals.TickCount()
			work.memDelta = getMemory() - work.memStart
			work.duration = work.endTime - work.startTime

			local workRecord = {
				key = work.name,
				name = work.name,
				category = work.category,
				source = "manual",
				scriptName = work.scriptName,
				line = 0,
				startTime = work.startTime,
				startTick = work.startTick,
				endTime = work.endTime,
				endTick = work.endTick,
				duration = work.duration,
				memDelta = work.memDelta,
				children = work.children,
			}

			local parentWork = ctx.activeCustomStack[#ctx.activeCustomStack]
			if parentWork then
				parentWork.children = parentWork.children or {}
				table.insert(parentWork.children, workRecord)
			else
				if #ctx.mainTimeline >= MAX_TIMELINE_SIZE then
					for i = 1, MAX_TIMELINE_SIZE - 1 do
						ctx.mainTimeline[i] = ctx.mainTimeline[i + 1]
					end
					ctx.mainTimeline[MAX_TIMELINE_SIZE] = workRecord
				else
					ctx.mainTimeline[#ctx.mainTimeline + 1] = workRecord
				end

				local timelineKey = work.category or work.scriptName or "Manual Work"
				if not ctx.scriptTimelines[timelineKey] then
					ctx.scriptTimelines[timelineKey] = {
						name = timelineKey,
						functions = {},
						type = "script",
					}
				end
				local funcs = ctx.scriptTimelines[timelineKey].functions
				if #funcs >= MAX_TIMELINE_SIZE then
					for i = 1, MAX_TIMELINE_SIZE - 1 do
						funcs[i] = funcs[i + 1]
					end
					funcs[MAX_TIMELINE_SIZE] = workRecord
				else
					funcs[#funcs + 1] = workRecord
				end
			end
		end

		inProfilerAPI = false
	end

	-- Get profiler data
	function MicroProfiler.GetMainTimeline()
		return currentContext.mainTimeline
	end

	function MicroProfiler.GetCustomThreads()
		return currentContext.customThreads
	end

	function MicroProfiler.GetScriptTimelines()
		return currentContext.scriptTimelines
	end

	function MicroProfiler.GetCallStack()
		return currentContext.callStack
	end

	function MicroProfiler.GetProfilerData()
		return {
			mainTimeline = currentContext.mainTimeline,
			customThreads = currentContext.customThreads,
			scriptTimelines = currentContext.scriptTimelines,
			callStack = currentContext.callStack,
			isEnabled = isEnabled,
			isHooked = isHooked,
			manualTimeline = currentContext.mainTimeline,
			contexts = Contexts,
			currentContext = currentContext,
		}
	end

	-- Clear collected data
	function MicroProfiler.ClearData()
		for _, ctx in pairs(Contexts) do
			ctx.mainTimeline = {}
			ctx.customThreads = {}
			ctx.activeCustomStack = {}
			ctx.callStack = {}
			ctx.scriptTimelines = {}
			ctx.callbackBoundaries = {}
			ctx.last_id = 0
			ctx.current_record = 1
		end
	end

	-- Reset profiler state
	function MicroProfiler.Reset()
		disableHook()
		MicroProfiler.ClearData()
		isEnabled = false
		isHooked = false
		isPaused = false
		inProfilerAPI = false
		lastCleanupTime = 0
		currentContext = Contexts.TICK
	end

	-- Set active context for profiling
	function MicroProfiler.SetContext(contextName)
		assert(contextName == "tick" or contextName == "frame", "SetContext: contextName must be 'tick' or 'frame'")

		local entryTime = getCurrentTime()

		if contextName == "tick" then
			local tickNum = globals.TickCount()
			currentContext = Contexts.TICK
			Shared.CurrentContext = "tick"
			autoShiftContext(currentContext, false)

			currentContext.callbackBoundaries[tickNum] = {
				startTime = entryTime,
				duration = globals.TickInterval(),
			}
		else
			local frameNum = globals.FrameCount()
			local frameDuration = globals.AbsoluteFrameTime()
			if frameDuration <= 0 or frameDuration > 1.0 then
				frameDuration = 1.0 / 60.0
			end

			currentContext = Contexts.FRAME
			Shared.CurrentContext = "frame"
			autoShiftContext(currentContext, true)

			Contexts.FRAME.last_id = frameNum
			Contexts.FRAME.callbackBoundaries[frameNum] = {
				startTime = entryTime,
				duration = frameDuration,
			}
		end
	end

	function MicroProfiler.GetCurrentContext()
		return currentContext.id
	end

	-- Get statistics
	function MicroProfiler.GetStats()
		local totalFunctions = 0
		local totalCustomThreads = 0
		local activeCustoms = 0
		local callStackDepth = 0
		local totalTime = 0
		local totalMemory = 0

		for _, ctx in pairs(Contexts) do
			totalFunctions = totalFunctions + #ctx.mainTimeline
			totalCustomThreads = totalCustomThreads + #ctx.customThreads
			activeCustoms = activeCustoms + #ctx.activeCustomStack
			callStackDepth = callStackDepth + #ctx.callStack

			for _, func in ipairs(ctx.mainTimeline) do
				totalTime = totalTime + (func.duration or 0)
				totalMemory = totalMemory + (func.memDelta or 0)
			end

			for _, thread in ipairs(ctx.customThreads) do
				totalTime = totalTime + (thread.duration or 0)
				totalMemory = totalMemory + (thread.memDelta or 0)
			end
		end

		return {
			totalFunctions = totalFunctions,
			totalCustomThreads = totalCustomThreads,
			activeCustoms = activeCustoms,
			callStackDepth = callStackDepth,
			totalTime = totalTime,
			totalMemory = totalMemory,
			isEnabled = isEnabled,
			isHooked = isHooked,
			currentContext = currentContext.id,
		}
	end

	-- Debug information
	function MicroProfiler.PrintStats()
		local stats = MicroProfiler.GetStats()
		print("=== MicroProfiler Stats ===")
		print("Enabled:", stats.isEnabled)
		print("Hooked:", stats.isHooked)
		print("Main timeline functions:", stats.totalFunctions)
		print("Custom threads:", stats.totalCustomThreads)
		print("Active custom threads:", stats.activeCustoms)
		print("Call stack depth:", stats.callStackDepth)
		-- Using Lua 5.4 enhanced string formatting
		print(string.format("Total time: %.6fs", stats.totalTime))
		print(string.format("Total memory: %.2fKB", stats.totalMemory))
	end

	-- Print timeline hierarchy (for debugging)
	function MicroProfiler.PrintTimeline(maxDepth)
		maxDepth = maxDepth or 3

		local function printNode(node, depth, prefix)
			if depth > maxDepth then
				return
			end

			local indent = string.rep("  ", depth)
			local name = node.name or node.key or "unknown"
			local duration = node.duration and string.format("%.3fms", node.duration * 1000) or "0ms"
			local memory = node.memDelta and string.format("%.1fKB", node.memDelta) or "0KB"

			-- Using Lua 5.4 enhanced string formatting
			print(string.format("%s%s%s | %s | %s", indent, prefix, name, duration, memory))

			if node.children then
				for i, child in ipairs(node.children) do
					local childPrefix = (i == #node.children) and "└─ " or "├─ "
					printNode(child, depth + 1, childPrefix)
				end
			end
		end

		print("=== Main Timeline (Current Context: " .. currentContext.id .. ") ===")
		for i, func in ipairs(currentContext.mainTimeline) do
			local prefix = (i == #currentContext.mainTimeline) and "└─ " or "├─ "
			printNode(func, 0, prefix)
		end

		print("=== Custom Threads ===")
		for i, thread in ipairs(currentContext.customThreads) do
			print("Thread: " .. (thread.name or "Unnamed"))
			for j, func in ipairs(thread.children) do
				local prefix = (j == #thread.children) and "└─ " or "├─ "
				printNode(func, 0, prefix)
			end
		end
	end

	-- Self-initialization
	-- Don't auto-enable, let the main profiler control this

	return MicroProfiler
end)
__bundle_register("Profiler.ui_body", function(require, _LOADED, __bundle_register, __bundle_modules)
	--[[
    UI Body Module - Main Profiler Display
    Handles the main profiler body with threads and function hierarchy
    Used by: profiler.lua
]]

	-- Imports
	local Shared = require("Profiler.Shared") --[[ Imported by: profiler ]]
	local config = require("Profiler.config")

	-- Module declaration
	local UIBody = {}

	-- Local constants / utilities -------- (Lua 5.4 compatible)
	local THREAD_HEIGHT = 24
	local THREAD_SPACING = 2
	local MIN_BAR_WIDTH = 2
	local HEADER_HEIGHT = 20
	local NESTING_INDENT = 16
	local DEFAULT_ZOOM = 1.0
	local MIN_ZOOM = 0.01    -- Much more zoom out
	local MAX_ZOOM = 100.0   -- Much more zoom in for precision
	local PAN_SPEED = 1.0
	local SNAP_ON_PAUSE = false -- Snap camera when pausing (disabled for free panning)

	-- Global variables for retained mode (not local)
	isVisible = isVisible or true
	viewportX = viewportX or 0 -- Camera position (horizontal)
	viewportY = viewportY or 0 -- Camera position (vertical)
	zoom = zoom or DEFAULT_ZOOM
	isDragging = isDragging or false
	dragStartX = dragStartX or 0
	dragStartY = dragStartY or 0
	lastMouseX = lastMouseX or 0
	lastMouseY = lastMouseY or 0

	-- External APIs with fallbacks (Lua 5.4 compatible)
	local draw = draw
	local input = input

	-- globals is a global table provided by the environment (RealTime, TickInterval, etc.)

	-- Key constants (Lua 5.4 compatible)
	local MOUSE_LEFT = MOUSE_LEFT or 107
	local MOUSE_WHEEL_UP = MOUSE_WHEEL_UP or 112
	local MOUSE_WHEEL_DOWN = MOUSE_WHEEL_DOWN or 113

	-- Font (global for retained mode)
	bodyFont = bodyFont or nil

	-- Click state (global for retained mode)
	clickState = clickState or {}

	-- Private helpers --------------------

	-- Safe coordinate conversion for drawing API
	local function safeCoord(value)
		-- Handle NaN, infinity, and nil
		if not value or value ~= value or value == math.huge or value == -math.huge then
			return 0
		end

		-- Convert to integer and clamp to reasonable screen bounds
		local coord = math.floor(value + 0.5)
		return math.max(-10000, math.min(10000, coord))
	end

	-- Safe rectangle drawing with bounds checking
	local function safeFilledRect(x1, y1, x2, y2)
		if not draw or not draw.FilledRect then
			return
		end

		local sx1 = safeCoord(x1)
		local sy1 = safeCoord(y1)
		local sx2 = safeCoord(x2)
		local sy2 = safeCoord(y2)

		-- Ensure x1 <= x2 and y1 <= y2
		if sx1 > sx2 then
			sx1, sx2 = sx2, sx1
		end
		if sy1 > sy2 then
			sy1, sy2 = sy2, sy1
		end

		-- Only draw if dimensions are reasonable
		if (sx2 - sx1) > 0 and (sy2 - sy1) > 0 and (sx2 - sx1) < 10000 and (sy2 - sy1) < 10000 then
			draw.FilledRect(sx1, sy1, sx2, sy2)
		end
	end

	local function initializeFont()
		if not bodyFont and draw and draw.CreateFont then
			-- Create a large, crisp, readable font for body text
			bodyFont = draw.CreateFont("Verdana", 18, 900) -- Much larger and very bold
		end
	end

	-- Use os.clock() for microsecond-level timing precision

	local function clamp(value, min, max)
		if value < min then
			return min
		end
		if value > max then
			return max
		end
		return value
	end

	-- Convert time to screen position with proper viewport handling
	local function timeToScreen(time, startTime, timeRange, screenWidth)
		-- Safety checks for division by zero and invalid inputs
		if not time or not startTime or not timeRange or not screenWidth then
			return 0
		end

		if timeRange <= 0 or screenWidth <= 0 then
			return 0
		end

		-- Check for NaN or infinity inputs
		if time ~= time or startTime ~= startTime or time == math.huge or time == -math.huge then
			return 0
		end

		-- Calculate time position with zoom and viewport offset
		local normalizedTime = (time - startTime) / timeRange
		if normalizedTime ~= normalizedTime then -- Check for NaN
			return 0
		end

		-- Apply zoom and viewport - viewport shifts the view horizontally
		local basePosition = normalizedTime * screenWidth * zoom
		local result = basePosition - viewportX

		-- Guard against extreme values
		if result ~= result or result > 1e9 or result < -1e9 then
			return 0
		end

		return safeCoord(result)
	end

	-- Convert screen position to time (Lua 5.4 enhanced with safety)
	local function screenToTime(screenX, startTime, timeRange, screenWidth)
		-- Safety checks for division by zero and invalid inputs
		if not screenX or not startTime or not timeRange or not screenWidth then
			return startTime or 0
		end

		if screenWidth <= 0 or timeRange <= 0 then
			return startTime
		end

		-- Check for NaN or infinity inputs
		if screenX ~= screenX or startTime ~= startTime or screenX == math.huge or screenX == -math.huge then
			return startTime
		end

		-- Safe division and bounds checking
		local denom = (screenWidth * zoom)
		if denom == 0 or denom ~= denom or denom == math.huge or denom == -math.huge then
			return startTime
		end
		local normalizedX = (screenX + viewportX) / denom
		if normalizedX ~= normalizedX then -- Check for NaN
			return startTime
		end

		local result = startTime + (normalizedX * timeRange)

		-- Final safety check before returning
		if result ~= result or result == math.huge or result == -math.huge then
			return startTime
		end

		return result
	end

	-- Get color for function based on name hash
	local function getFunctionColor(name)
		local hash = 0
		for i = 1, #name do
			hash = hash + string.byte(name, i)
		end
		local r = (hash * 73) % 200 + 55
		local g = (hash * 151) % 200 + 55
		local b = (hash * 211) % 200 + 55
		return r, g, b
	end

	-- Get thread color based on type
	local function getThreadColor(threadType)
		if threadType == "main" then
			return 100, 150, 200 -- Blue for main timeline
		elseif threadType == "custom" then
			return 150, 100, 200 -- Purple for custom threads
		elseif threadType == "script" then
			return 100, 200, 150 -- Green for script timelines
		else
			return 120, 120, 120 -- Gray for unknown
		end
	end

	-- Draw a function bar with script name
	local function drawFunctionBar(func, y, depth, startTime, timeRange, screenWidth, threadType)
		if not func.startTime or not func.endTime then
			return
		end

		local duration = func.endTime - func.startTime
		-- Always show bars even for very fast functions
		if duration < 0 then
			duration = 0.001 -- Minimum 1ms for visibility
		end

		local x1 = timeToScreen(func.startTime, startTime, timeRange, screenWidth)
		local x2 = timeToScreen(func.endTime, startTime, timeRange, screenWidth)
		local calculatedWidth = x2 - x1
		-- Show exact time usage, no artificial minimum width
		local width = calculatedWidth

		-- Skip if completely out of view (but debug why)
		if x2 < 0 or x1 > screenWidth then
			print(
				string.format(
					"⚠️ Function %s SKIPPED: x1=%.0f, x2=%.0f, screenWidth=%d (out of view)",
					func.name or "unnamed",
					x1,
					x2,
					screenWidth
				)
			)
			return
		end

		-- Calculate position with nesting indent
		local indentedY = y + depth * NESTING_INDENT
		local barHeight = THREAD_HEIGHT - 4

		-- Get function color
		local r, g, b = getFunctionColor(func.name or func.key or "unknown")

		-- Draw function bar
		if draw then
			-- Optional debug (guarded)
			if Shared and Shared.DEBUG then
				if not _barDebugCount then
					_barDebugCount = 0
				end
				_barDebugCount = _barDebugCount + 1
				if _barDebugCount <= 3 then
					print(
						string.format(
							"🎨 Drawing bar: %s at x1=%.0f, width=%.0f, y=%.0f",
							func.name or "unnamed",
							x1,
							width,
							indentedY
						)
					)
				end
			end

			draw.Color(r, g, b, 180)
			safeFilledRect(x1, indentedY, x1 + width, indentedY + barHeight)

			-- Draw border
			draw.Color(255, 255, 255, 100)
			draw.OutlinedRect(
				math.floor(x1),
				math.floor(indentedY),
				math.floor(x1 + width),
				math.floor(indentedY + barHeight)
			)

			-- Script name is already shown in the green header, no need to repeat it on each function

			-- Draw text if bar is wide enough (check actual text width)
			local name = func.name or func.key or "unknown"
			local nameWidth = 0
			if draw.GetTextSize then
				nameWidth = draw.GetTextSize(name)[1] or 0
			else
				-- Fallback estimate: ~8 pixels per character
				nameWidth = #name * 8
			end

			if width > (nameWidth + 16) then -- Need space for text + padding
				draw.Color(255, 255, 255, 255)
				draw.Text(math.floor(x1 + 8), math.floor(indentedY + 4), name)

				-- Show duration if there's additional space
				local durationMs = duration * 1000
				local timeText = string.format("%.1fms", durationMs)
				local timeWidth = 0
				if draw.GetTextSize then
					timeWidth = draw.GetTextSize(timeText)[1] or 0
				else
					timeWidth = #timeText * 8
				end

				if width > (nameWidth + timeWidth + 24) then -- Space for both texts
					draw.Color(255, 255, 100, 255) -- Yellow for visibility
					draw.Text(math.floor(x1 + 8), math.floor(indentedY + 22), timeText)
				end
			elseif width > 20 then
				-- Very narrow bar - just show first few characters
				local shortName = string.sub(name, 1, math.max(1, math.floor(width / 8) - 1))
				draw.Color(255, 255, 255, 200)
				draw.Text(math.floor(x1 + 2), math.floor(indentedY + 4), shortName)
			end
		end

		return indentedY + barHeight + 2
	end

	-- Check if two functions overlap in time
	local function functionsOverlap(func1, func2)
		if not func1.startTime or not func1.endTime or not func2.startTime or not func2.endTime then
			return false
		end
		local overlap = not (func1.endTime <= func2.startTime or func2.endTime <= func1.startTime)
		if overlap then
			print(
				string.format(
					"⚠️ OVERLAP: %s (%.3f-%.3f) vs %s (%.3f-%.3f)",
					func1.name or "unnamed",
					func1.startTime,
					func1.endTime,
					func2.name or "unnamed",
					func2.startTime,
					func2.endTime
				)
			)
		end
		return overlap
	end

	-- Draw function hierarchy with proper stacking for overlapping functions
	local function drawFunctionHierarchy(functions, baseY, startTime, timeRange, screenWidth, threadType)
		local currentY = baseY
		local stackLevels = {} -- Track which Y levels are occupied by time ranges

		print(
			string.format("🎨 Drawing hierarchy: %d functions, baseY=%.0f, timeRange=%.3f", #functions, baseY, timeRange)
		)

		for i, func in ipairs(functions) do
			-- Find the appropriate Y level for this function
			local level = 0
			local foundLevel = false

			-- Check existing stack levels for conflicts
			while not foundLevel do
				local conflictFound = false
				for _, occupiedFunc in ipairs(stackLevels[level] or {}) do
					if functionsOverlap(func, occupiedFunc) then
						conflictFound = true
						break
					end
				end

				if not conflictFound then
					-- This level is free, use it
					if not stackLevels[level] then
						stackLevels[level] = {}
					end
					table.insert(stackLevels[level], func)
					foundLevel = true
				else
					-- Try next level
					level = level + 1
				end
			end

			-- Draw this function at the determined level
			local functionY = baseY + (level * (THREAD_HEIGHT + THREAD_SPACING))
			print(
				string.format("  Drawing function %d: %s at level %d, Y=%.0f", i, func.name or "unnamed", level,
					functionY)
			)
			local newY = drawFunctionBar(func, functionY, 0, startTime, timeRange, screenWidth, threadType)

			-- Update currentY to track the maximum used Y
			currentY = math.max(currentY, functionY + THREAD_HEIGHT + THREAD_SPACING)

			-- Draw children with indentation (children get their own stacking context)
			if func.children and #func.children > 0 then
				local childrenY =
					drawFunctionHierarchy(func.children, currentY, startTime, timeRange, screenWidth, threadType)
				currentY = math.max(currentY, childrenY)
			end
		end

		return currentY
	end

	-- Draw a thread
	local function drawThread(thread, y, startTime, timeRange, screenWidth)
		if not draw then
			return y
		end

		local threadType = thread.type or "main"
		local r, g, b = getThreadColor(threadType)

		-- Draw thread header
		draw.Color(r, g, b, 200)
		safeFilledRect(0, y, screenWidth, y + HEADER_HEIGHT)

		-- Draw thread border
		draw.Color(255, 255, 255, 150)
		draw.OutlinedRect(0, math.floor(y), screenWidth, math.floor(y + HEADER_HEIGHT))

		-- Draw thread name
		draw.Color(255, 255, 255, 255)
		local threadName = thread.name or "Main Timeline"
		draw.Text(6, math.floor(y + 4), threadName)

		-- ALWAYS show thread info even if no duration/memory
		local functionCount = (thread.functions and #thread.functions) or 0
		local infoText = string.format("(%d functions)", functionCount)
		if thread.duration then
			local durationMs = thread.duration * 1000
			infoText = string.format("%.2fms | %s", durationMs, infoText)
			if thread.memDelta then
				infoText = infoText .. string.format(" | %.1fKB", thread.memDelta)
			end
		end
		draw.Color(220, 220, 220, 255)
		draw.Text(150, math.floor(y + 4), infoText)

		local contentY = y + HEADER_HEIGHT + 2

		-- Draw function hierarchy
		if thread.functions and #thread.functions > 0 then
			contentY = drawFunctionHierarchy(thread.functions, contentY, startTime, timeRange, screenWidth, threadType)
		end

		return contentY + THREAD_SPACING * 2
	end

	-- Handle input (ALWAYS active when body is visible and paused)
	local function handleInput(screenWidth, screenHeight, topBarHeight)
		-- FORCE input to work - don't check for input existence
		if not input or not input.GetMousePos then
			return
		end

		local pos = input.GetMousePos()
		local mx, my = pos[1] or 0, pos[2] or 0

		-- Only handle input in body area (below top bar)
		if my < topBarHeight then
			return
		end

		-- Adjust mouse position for body area
		local bodyMy = my - topBarHeight

		-- Handle dragging - FORCE detection
		local currentlyDragging = input.IsButtonDown and input.IsButtonDown(MOUSE_LEFT)
		local wasDragging = clickState["drag_active"] or false

		if currentlyDragging and not wasDragging then
			-- Start drag
			clickState["drag_active"] = true
			isDragging = true
			dragStartX = mx
			dragStartY = bodyMy
			lastMouseX = mx
			lastMouseY = bodyMy
			print(string.format("🎯 DRAG START: mx=%d, my=%d", mx, bodyMy))
		elseif currentlyDragging and isDragging then
			-- Continue drag - apply both X and Y movement
			local deltaX = mx - lastMouseX
			local deltaY = bodyMy - lastMouseY

			if math.abs(deltaX) > 1 or math.abs(deltaY) > 1 then -- Require minimum movement
				viewportX = viewportX - deltaX * PAN_SPEED
				viewportY = viewportY - deltaY * PAN_SPEED
				print(
					string.format(
						"🎯 DRAGGING: deltaX=%d, deltaY=%d, viewportX=%.1f, viewportY=%.1f",
						deltaX,
						deltaY,
						viewportX,
						viewportY
					)
				)
			end

			lastMouseX = mx
			lastMouseY = bodyMy
		elseif not currentlyDragging and wasDragging then
			-- Release drag
			clickState["drag_active"] = false
			isDragging = false
			print("🎯 DRAG END")
		end

		-- Handle zoom with MOUSE WHEEL - FORCE detection
		if input.IsButtonDown then
			local wheelUpNow = input.IsButtonDown(112)
			local wheelDownNow = input.IsButtonDown(113)

			if wheelUpNow and not clickState["wheel_up"] then
				local oldZoom = zoom
				zoom = clamp(zoom * 1.2, MIN_ZOOM, MAX_ZOOM)
				clickState["wheel_up"] = true
				print(string.format("🎯 ZOOM IN: %.3f -> %.3f", oldZoom, zoom))
			elseif not wheelUpNow and clickState["wheel_up"] then
				clickState["wheel_up"] = false
			end

			if wheelDownNow and not clickState["wheel_down"] then
				local oldZoom = zoom
				zoom = clamp(zoom / 1.2, MIN_ZOOM, MAX_ZOOM)
				clickState["wheel_down"] = true
				print(string.format("🎯 ZOOM OUT: %.3f -> %.3f", oldZoom, zoom))
			elseif not wheelDownNow and clickState["wheel_down"] then
				clickState["wheel_down"] = false
			end
		end
	end

	-- Public API -------------------------

	function UIBody.Initialize()
		initializeFont()
		isVisible = true
		viewportX = 0
		viewportY = 0
		zoom = DEFAULT_ZOOM
		isDragging = false
	end

	function UIBody.SetVisible(visible)
		isVisible = visible
	end

	function UIBody.IsVisible()
		return isVisible
	end

	function UIBody.ToggleVisible()
		isVisible = not isVisible
		return isVisible
	end

	function UIBody.Draw(profilerData, topBarHeight)
		if not isVisible or not draw or not profilerData then
			return
		end

		local screenW, screenH = draw.GetScreenSize()
		local bodyHeight = screenH - topBarHeight

		-- Set font
		if bodyFont and draw.SetFont then
			draw.SetFont(bodyFont)
		end

		-- Trigger stats debug output (every 5s) only when DEBUG
		local MicroProfiler = require("Profiler.microprofiler")
		if Shared and Shared.DEBUG then
			MicroProfiler.GetStats()
		end

		-- Draw body background
		draw.Color(25, 25, 25, 220)
		safeFilledRect(0, topBarHeight, screenW, screenH)

		-- FIXED TIME WINDOW: constant 5 seconds for body navigation
		local currentTime = os.clock()
		local timeWindow = 5.0 / zoom -- 5-second window scaled by zoom

		-- When paused, freeze the timeline scope
		if not frozenTimeScope then
			frozenTimeScope = {}
		end

		local isPaused = false
		-- Check if paused from UI
		local UITop = require("Profiler.ui_top")
		if UITop and UITop.IsPaused then
			isPaused = UITop.IsPaused()
		end

		-- Detect pause transitions for snapping
		if _wasPaused == nil then
			_wasPaused = isPaused
		end

		local startTime, endTime, timeRange
		if isPaused then
			-- PAUSED: Use frozen scope + user navigation
			if not frozenTimeScope.center then
				-- Auto-center on middle of all recorded data (not just latest)
				local earliest, latest = math.huge, -math.huge
				if profilerData.scriptTimelines then
					for _, scriptData in pairs(profilerData.scriptTimelines) do
						if scriptData.functions then
							for _, func in ipairs(scriptData.functions) do
								if func.startTime and func.endTime then
									earliest = math.min(earliest, func.startTime)
									latest = math.max(latest, func.endTime)
								end
							end
						end
					end
				end
				if earliest ~= math.huge and latest ~= -math.huge then
					frozenTimeScope.center = (earliest + latest) / 2 -- Center on middle of data
				else
					frozenTimeScope.center = currentTime -- Fallback
				end
			end
			-- If a frame is selected in top bar, center on frozen scope; horizontal navigation handled by viewportX in timeToScreen
			local centerTime = frozenTimeScope.center
			local halfWindow = timeWindow / 2
			startTime = centerTime - halfWindow
			endTime = centerTime + halfWindow
			timeRange = timeWindow

			-- Snap on transition to paused
			if SNAP_ON_PAUSE and (not _wasPaused and isPaused) then
				-- Calculate bounds and snap horizontally to nearest function start
				local function getDataTimeBounds()
					local earliest, latest = math.huge, -math.huge
					local function consider(node)
						if node.startTime and node.endTime then
							earliest = math.min(earliest, node.startTime)
							latest = math.max(latest, node.endTime)
						end
					end
					if profilerData.scriptTimelines then
						for _, scriptData in pairs(profilerData.scriptTimelines) do
							if scriptData.functions then
								for _, f in ipairs(scriptData.functions) do
									consider(f)
								end
							end
						end
					end
					if profilerData.mainTimeline then
						for _, f in ipairs(profilerData.mainTimeline) do
							consider(f)
						end
					end
					return earliest, latest
				end

				local earliest, latest = getDataTimeBounds()
				if earliest ~= math.huge and latest ~= -math.huge then
					-- Find nearest record start to centerTime
					local nearest = centerTime
					local bestDist = math.huge
					local function checkNearest(list)
						for _, f in ipairs(list) do
							if f.startTime then
								local d = math.abs(f.startTime - centerTime)
								if d < bestDist then
									bestDist = d
									nearest = f.startTime
								end
							end
						end
					end
					if profilerData.scriptTimelines then
						for _, scriptData in pairs(profilerData.scriptTimelines) do
							if scriptData.functions then
								checkNearest(scriptData.functions)
							end
						end
					end
					if profilerData.mainTimeline then
						checkNearest(profilerData.mainTimeline)
					end

					-- Convert desired time shift into viewportX shift so that window centers on nearest
					local desiredShift = nearest - centerTime -- seconds
					local pixelsPerWindow = (screenW * zoom)
					local px = (desiredShift / timeRange) * pixelsPerWindow
					viewportX = viewportX - px -- apply shift via viewport mapping
				end

				-- Snap vertically to top
				viewportY = 0
			end
		else
			-- RUNNING: Follow current time (moving timeline)
			frozenTimeScope.center = nil -- Clear frozen scope
			local halfWindow = timeWindow / 2
			startTime = currentTime - halfWindow
			endTime = currentTime + halfWindow
			timeRange = timeWindow
		end

		-- Track pause state for next frame
		_wasPaused = isPaused

		-- Reduced debug spam
		if isPaused and not _timeDebugCount then
			_timeDebugCount = 0
		end
		if isPaused then
			_timeDebugCount = _timeDebugCount + 1
			if _timeDebugCount > 120 then -- Show every 2 seconds
				_timeDebugCount = 0
				print(
					string.format(
						"🕒 Time window: %.3fs - %.3fs (%.3fs range, zoom: %.2fx)",
						startTime,
						endTime,
						timeRange,
						zoom
					)
				)
			end
		end

		-- Viewport bounds: clamp to available content/time
		if viewportX ~= viewportX or viewportX == math.huge or viewportX == -math.huge then
			viewportX = 0
		end
		if viewportY ~= viewportY or viewportY == math.huge or viewportY == -math.huge then
			viewportY = 0
		end

		-- Calculate actual rendered content height (match the drawing logic)
		local simulatedY = topBarHeight + 10 - viewportY -- Same as currentY calculation
		local actualContentBottom = simulatedY

		-- Simulate drawing to find actual bottom
		if profilerData.scriptTimelines then
			for scriptName, scriptData in pairs(profilerData.scriptTimelines) do
				if scriptData.functions then
					-- Each script adds: header + functions + spacing
					actualContentBottom = actualContentBottom + HEADER_HEIGHT + 2
					actualContentBottom = actualContentBottom +
						(#scriptData.functions * (THREAD_HEIGHT + THREAD_SPACING))
					actualContentBottom = actualContentBottom + THREAD_SPACING * 2
				end
			end
		end

		-- Add main timeline
		if profilerData.mainTimeline and #profilerData.mainTimeline > 0 then
			actualContentBottom = actualContentBottom
				+ HEADER_HEIGHT
				+ (#profilerData.mainTimeline * (THREAD_HEIGHT + THREAD_SPACING))
				+ 20
		end

		-- Add custom threads
		if profilerData.customThreads then
			for _, thread in ipairs(profilerData.customThreads) do
				if thread.children and #thread.children > 0 then
					actualContentBottom = actualContentBottom
						+ HEADER_HEIGHT
						+ (#thread.children * (THREAD_HEIGHT + THREAD_SPACING))
						+ 20
				end
			end
		end

		-- Calculate proper viewportY limits (only clamp when running)
		local bodyHeight = screenH - topBarHeight
		local contentHeight = actualContentBottom - (topBarHeight + 10) -- Remove initial offset
		local maxViewportY = math.max(0, contentHeight - bodyHeight + 20) -- Add small buffer
		if not isPaused then
			viewportY = clamp(viewportY, 0, maxViewportY)
		end

		-- Horizontal clamping is disabled when paused so panning remains free

		local currentY = topBarHeight + 10 - viewportY

		-- Draw script timelines (separate stacks per script) - FORCE DISPLAY
		if profilerData.scriptTimelines then
			for scriptName, scriptData in pairs(profilerData.scriptTimelines) do
				if scriptData.functions then
					local scriptThread = {
						name = "Script: " .. scriptName,
						type = "script",
						functions = scriptData.functions,
						duration = timeRange,
					}
					-- DEBUG: Always show function count and time ranges
					print(
						string.format("📊 Drawing script timeline: %s (%d functions)", scriptName, #scriptData.functions)
					)
					for i, func in ipairs(scriptData.functions) do
						if i <= 3 then -- Show first 3 functions
							print(
								string.format(
									"  Function %d: %s (%.3f-%.3f, duration: %.3fms)",
									i,
									func.name or "unnamed",
									func.startTime or 0,
									func.endTime or 0,
									(func.duration or 0) * 1000
								)
							)
						end
					end

					-- ALWAYS draw the thread header even if no functions yet
					currentY = drawThread(scriptThread, currentY, startTime, timeRange, screenW)
				end
			end
		else
			-- Show debug info if no script timelines
			draw.Color(255, 255, 0, 255)
			draw.Text(10, currentY, "⚠️ No script timelines found")
			currentY = currentY + 25
		end

		-- Draw main timeline thread (fallback/combined view)
		if profilerData.mainTimeline and #profilerData.mainTimeline > 0 then
			local mainThread = {
				name = "All Scripts (Combined)",
				type = "main",
				functions = profilerData.mainTimeline,
				duration = timeRange,
			}
			currentY = drawThread(mainThread, currentY, startTime, timeRange, screenW)
		end

		-- Draw custom threads (manual profiling)
		if profilerData.customThreads then
			for _, thread in ipairs(profilerData.customThreads) do
				if thread.children and #thread.children > 0 then
					local customThread = {
						name = "Custom: " .. (thread.name or "Unnamed"),
						type = "custom",
						functions = thread.children,
						duration = thread.duration,
						memDelta = thread.memDelta,
					}
					currentY = drawThread(customThread, currentY, startTime, timeRange, screenW)
				end
			end
		end

		-- ALWAYS draw zoom and pan info (READABLE - integer coordinates)
		draw.Color(255, 255, 255, 255) -- Bright white
		draw.Text(
			10,
			screenH - 90,
			string.format("Zoom: %.2fx (Window: %.3fs) %s", zoom, timeWindow, isPaused and "[FROZEN]" or "[LIVE]")
		)
		draw.Text(10, screenH - 75, string.format("Pan: X=%.0f Y=%.0f", viewportX, viewportY))
		draw.Text(10, screenH - 60, string.format("Time: %.3fs - %.3fs", startTime, endTime))
		draw.Text(10, screenH - 45, "Drag=Pan, Wheel=Zoom, P=Pause")

		-- Debug input state
		local mousePos = (input and input.GetMousePos) and input.GetMousePos() or { 0, 0 }
		local mouseDown = (input and input.IsButtonDown) and input.IsButtonDown(MOUSE_LEFT) or false
		draw.Text(
			10,
			screenH - 30,
			string.format(
				"Mouse: %d,%d Down:%s Drag:%s",
				mousePos[1] or 0,
				mousePos[2] or 0,
				tostring(mouseDown),
				tostring(isDragging)
			)
		)
		draw.Text(10, screenH - 15, string.format("Input API: %s", (input and "OK") or "MISSING"))

		-- DEBUG: Show data status
		local totalFunctions = 0
		if profilerData.scriptTimelines then
			for _, scriptData in pairs(profilerData.scriptTimelines) do
				totalFunctions = totalFunctions + #scriptData.functions
			end
		end
		if profilerData.mainTimeline then
			totalFunctions = totalFunctions + #profilerData.mainTimeline
		end
		if profilerData.customThreads then
			totalFunctions = totalFunctions + #profilerData.customThreads
		end

		-- Count script timelines
		local scriptCount = 0
		if profilerData.scriptTimelines then
			for _ in pairs(profilerData.scriptTimelines) do
				scriptCount = scriptCount + 1
			end
		end

		draw.Color(255, 255, 0, 255)
		draw.Text(10, screenH - 10, string.format("Data: %d functions, %d scripts", totalFunctions, scriptCount))

		-- Handle input
		handleInput(screenW, screenH, topBarHeight)
	end

	function UIBody.ResetCamera()
		viewportX = 0
		viewportY = 0
		zoom = DEFAULT_ZOOM
	end

	function UIBody.SetZoom(newZoom)
		zoom = clamp(newZoom, MIN_ZOOM, MAX_ZOOM)
	end

	function UIBody.GetZoom()
		return zoom
	end

	function UIBody.SetViewport(x, y)
		viewportX = x
		viewportY = y
	end

	function UIBody.GetViewport()
		return viewportX, viewportY
	end

	-- Center the timeline on a specific global timestamp (called from top bar)
	function UIBody.CenterOnTimestamp(timestamp)
		if not timestamp then
			return
		end
		-- Set frozen center and reset pan for precise jump
		if not frozenTimeScope then
			frozenTimeScope = {}
		end
		frozenTimeScope.center = timestamp
		viewportX = 0
	end

	return UIBody
end)
__bundle_register("Profiler.config", function(require, _LOADED, __bundle_register, __bundle_modules)
	--[[
    Profiler Configuration File
    Modify these values to customize profiler behavior
]]

	return {
		-- Display settings
		visible = true,        -- Start with profiler visible or hidden
		windowSize = 60,       -- Number of frames to average over (1-300)
		sortMode = "size",     -- "size" (biggest first), "static" (measurement order), "reverse" (smallest first)
		systemHeight = 48,     -- Height of each system bar in pixels
		fontSize = 12,         -- Font size for text
		maxSystems = 20,       -- Maximum number of systems to display
		textPadding = 6,       -- Padding around text in components
		smoothingSpeed = 2.5,  -- Percentage of width to move per frame towards target (1-50%, higher = less smooth but more responsive)
		smoothingDecay = 1.5,  -- Percentage of width to move per frame when decaying (1-50%, lower = slower decay, peaks stay longer)
		textUpdateInterval = 20, -- Update text every N frames (20 frames = 333ms at 60fps, 3 times per second max)
		systemMemoryMode = "system", -- "system" (actual system memory usage) or "components" (sum of component memory)
	}
end)
return __bundle_require("__root")
