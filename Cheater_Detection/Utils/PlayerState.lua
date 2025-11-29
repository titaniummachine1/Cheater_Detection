--[[ PlayerState.lua
     Central storage for per-player runtime data.
     Ensures a single source of truth that is populated only for
     players currently in the server.
]]

local G = require("Cheater_Detection.Utils.Globals")

local PlayerState = {}

---@type table<string, table>
local ActivePlayers = {}
G.PlayerData = ActivePlayers -- Maintain backwards compatibility

local function newVector(vec)
	if not vec then
		return Vector3(0, 0, 0)
	end
	return Vector3(vec.x, vec.y, vec.z)
end

local function newAngles(ang)
	if not ang then
		return EulerAngles(0, 0, 0)
	end
	return EulerAngles(ang.x, ang.y, ang.z)
end

local function createHistoryRecord()
	return {
		Angle = EulerAngles(0, 0, 0),
		Hitboxes = {
			Head = Vector3(0, 0, 0),
			Body = Vector3(0, 0, 0),
		},
		SimTime = 0,
		onGround = true,
		StdDev = 1,
		FiredGun = false,
	}
end

local function createCurrent()
	return {
		Angle = EulerAngles(0, 0, 0),
		Hitboxes = {
			Head = Vector3(0, 0, 0),
			Body = Vector3(0, 0, 0),
		},
		SimTime = 0,
		onGround = true,
		FiredGun = false,
	}
end

local function createInfo()
	return {
		Name = "Unknown",
		IsCheater = false,
		bhop = 0,
		LastOnGround = true,
		LastVelocity = Vector3(0, 0, 0),
		LastStrike = 0,
	}
end

local function createEvidence()
	return {
		TotalScore = 0,
		LastUpdateTick = 0,
		Reasons = {},
	}
end

local function createState()
	return {
		Entity = nil,
		info = createInfo(),
		Evidence = createEvidence(),
		Current = createCurrent(),
		History = { createHistoryRecord() },
		LastSeenTick = 0,
	}
end

---Return the internal storage table (legacy compatibility)
---@return table<string, table>
function PlayerState.GetTable()
	return ActivePlayers
end

---Create or fetch a player's state table
---@param steamID string
---@return table|nil
function PlayerState.Get(steamID)
	if not steamID then
		return nil
	end
	-- steamID = tostring(steamID) -- Use raw key
	return ActivePlayers[steamID]
end

---Create or fetch a player's state table
---@param steamID string
---@return table|nil
function PlayerState.GetOrCreate(steamID)
	if not steamID then
		return nil
	end

	-- steamID = tostring(steamID) -- Use raw key
	local state = ActivePlayers[steamID]
	if not state then
		state = createState()
		ActivePlayers[steamID] = state
	end

	state.LastSeenTick = globals.TickCount()
	return state
end

function PlayerState.GetHistory(steamID)
	local state = PlayerState.GetOrCreate(steamID)
	if not state then
		return nil
	end
	state.History = state.History or { createHistoryRecord() }
	return state.History
end

function PlayerState.PushHistory(steamID, record, maxHistory)
	if not steamID or not record then
		return
	end
	local state = PlayerState.GetOrCreate(steamID)
	if not state then
		return
	end
	state.History = state.History or {}
	state.History[#state.History + 1] = record
	state.Current = record
	local limit = maxHistory or 66
	if #state.History > limit then
		table.remove(state.History, 1)
	end
end

---Attach runtime info from a WrappedPlayer to its state table
---@param wrapped table
---@return table|nil
function PlayerState.AttachWrappedPlayer(wrapped)
	if not wrapped or type(wrapped.GetSteamID64) ~= "function" then
		return nil
	end

	local steamID = wrapped:GetSteamID64()
	if not steamID then
		return nil
	end

	local state = PlayerState.GetOrCreate(steamID)
	if not state then
		return nil
	end
	state.Entity = wrapped:GetRawEntity()

	state.info = state.info or createInfo()

	if wrapped.GetName then
		local name = wrapped:GetName()
		if name and name ~= "" then
			state.info.Name = name
		end
	end

	if wrapped.GetTeamNumber then
		state.info.Team = wrapped:GetTeamNumber()
	end

	return state
end

---Ensure only actively tracked players remain in memory
---@param activeSet table<string, boolean>
function PlayerState.TrimToActive(activeSet)
	if not activeSet then
		return
	end

	for steamID, state in pairs(ActivePlayers) do
		if not activeSet[steamID] then
			-- Preserve persistent data (Evidence, info) but clear tick-based data
			-- This allows Evidence decay to continue even when player is not in current list
			local hasEvidence = state.Evidence and state.Evidence.TotalScore and state.Evidence.TotalScore > 0

			if hasEvidence then
				-- Keep persistent data, clear tick-based data only
				state.Entity = nil
				state.Current = nil
				state.History = nil
				state.LastSeenTick = 0

				if G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug then
					print(
						string.format(
							"[PlayerState] Preserved Evidence for inactive player %s (Score: %.1f)",
							steamID,
							state.Evidence.TotalScore
						)
					)
				end
			else
				-- No evidence, safe to delete entirely
				if G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug then
					print(string.format("[PlayerState] TRIMMING %s (no evidence)", steamID))
				end
				ActivePlayers[steamID] = nil
			end
		end
	end
end

---Remove every tracked player (e.g., on disconnect/map change)
function PlayerState.Reset()
	for steamID in pairs(ActivePlayers) do
		ActivePlayers[steamID] = nil
	end
end

return PlayerState
