local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local G = require("Cheater_Detection.Utils.Globals")
local Constants = require("Cheater_Detection.Core.constants")
local PlayerCache = require("Cheater_Detection.Core.player_cache")
local VDFParser = require("Cheater_Detection.Utils.VDFParser")

local CosmeticAbuse = {}

-- Regions that conflict with each other when worn together.
-- "whole_head" blocks all other head regions; anything in this set conflicts if worn with whole_head.
local WHOLE_HEAD_CONFLICTS = {
	hat = true,
	face = true,
	glasses = true,
	lenses = true,
	ears = true,
	headphones = true,
	head_misc = true,
	hat_lower = true,
}

-- defIndex -> equip_region string (or false if no region); avoids repeated lookups
local regionCache = {}

-- per-player scan results: id -> { regions = {region->count}, totalWearables = n }
local playerScanData = {}

-- One entities.FindByClass("CTFWearable") pass per game tick, shared by all players.
local wearableCacheTick = -1
local wearablesByPlayerIndex = {}

local function readPropInt(ent, propName)
	local value = ent:GetPropInt(propName)
	if type(value) ~= "number" then return nil end
	return value
end

local function getItemName(defIndex)
	if not itemschema then return nil end
	local itemDef = itemschema.GetItemDefinitionByID(defIndex)
	if not itemDef then return nil end
	local name = itemDef:GetName()
	return (type(name) == "string" and name ~= "") and name or nil
end

local function getItemRegion(defIndex)
	if regionCache[defIndex] ~= nil then
		return regionCache[defIndex] or nil
	end
	local region = VDFParser.GetEquipRegion(defIndex)
	regionCache[defIndex] = region or false
	return region
end

-- Cosmetic loadout slots to check directly on each player entity
local COSMETIC_SLOTS = {
	LOADOUT_POSITION_HEAD,
	LOADOUT_POSITION_MISC,
	LOADOUT_POSITION_MISC2,
	LOADOUT_POSITION_ACTION,
}

local function refreshWearableCacheForTick()
	local tick = globals.TickCount()
	if wearableCacheTick == tick then
		return
	end
	wearableCacheTick = tick
	wearablesByPlayerIndex = {}

	for _, wearable in pairs(entities.FindByClass("CTFWearable")) do
		if wearable and wearable:IsValid() then
			local owner = wearable:GetPropEntity("m_hOwnerEntity")
			local parent = wearable:GetPropEntity("m_hMoveParent")
			local ownerIdx = owner and owner:IsValid() and owner:GetIndex()
			local parentIdx = parent and parent:IsValid() and parent:GetIndex()
			local playerIdx = ownerIdx or parentIdx
			if playerIdx then
				local list = wearablesByPlayerIndex[playerIdx]
				if not list then
					list = {}
					wearablesByPlayerIndex[playerIdx] = list
				end
				list[#list + 1] = wearable
			end
		end
	end
end

local function scanPlayerWearables(player, targetID, isDebug)
	if not player then return false end

	local playerIdx = player:GetIndex()
	local data = { regions = {}, totalWearables = 0 }
	if isDebug then data.slotNames = {} end
	local seenEntIndex = {}

	local function processWearable(item)
		if not item or not item:IsValid() then return end
		local entIdx = item:GetIndex()
		if seenEntIndex[entIdx] then return end
		seenEntIndex[entIdx] = true

		local defIndex = readPropInt(item, "m_iItemDefinitionIndex")
		if not defIndex or defIndex <= 0 then return end

		local region = getItemRegion(defIndex)
		if region then
			data.regions[region] = (data.regions[region] or 0) + 1
		end
		if isDebug then
			local n = data.totalWearables + 1
			data.slotNames[n] = string.format("%s [%d]%s",
				getItemName(defIndex) or "?", defIndex,
				region and (" region=" .. region) or "")
		end
		data.totalWearables = data.totalWearables + 1
	end

	-- Primary: wearables from one shared per-tick cache (avoids FindByClass per player).
	refreshWearableCacheForTick()
	local cachedWearables = wearablesByPlayerIndex[playerIdx]
	if cachedWearables then
		for i = 1, #cachedWearables do
			processWearable(cachedWearables[i])
		end
	end

	-- Secondary: loadout slots 7-12, catches anything the entity scan missed.
	for slot = 7, 12 do
		local item = player:GetEntityForLoadoutSlot(slot)
		if item then
			processWearable(item)
		end
	end

	if data.totalWearables == 0 then
		-- Only log zero wearables for real players in debug, not bots
		if isDebug and targetID:sub(1, 4) ~= "BOT_" then
			print(string.format("[CosmeticAbuse] id=%s - 0 wearables found", targetID))
		end
		return false
	end

	playerScanData[targetID] = data

	if isDebug then
		local parts = { string.format("[CosmeticAbuse] id=%s wearables=%d", targetID, data.totalWearables) }
		if data.slotNames then
			for i, label in pairs(data.slotNames) do
				parts[#parts + 1] = string.format("  item%d: %s", i, label)
			end
		end
		print(table.concat(parts, "\n"))
	end

	return data
end

local function checkConflicts(id)
	local data = playerScanData[id]
	if not data then return false, nil end

	local regions = data.regions

	-- 1. Any region equipped more than once = direct conflict
	for region, count in pairs(regions) do
		if count > 1 then
			return true, string.format("duplicate equip_region '%s' x%d", region, count)
		end
	end

	-- 2. whole_head conflicts with any other head-area region
	if regions["whole_head"] then
		for region in pairs(regions) do
			if region ~= "whole_head" and WHOLE_HEAD_CONFLICTS[region] then
				return true, string.format("whole_head conflicts with '%s'", region)
			end
		end
	end

	return false, nil
end

local function isEnabled()
	local menu = G.Menu
	local advanced = menu and menu.Advanced
	if not advanced then return false end
	return advanced.Cosmetics == true
end

function CosmeticAbuse.Init()
	VDFParser.LoadItemsGame()
end

function CosmeticAbuse.InvalidatePlayer(id)
	playerScanData[id] = nil
	local state = PlayerCache.GetByID(id)
	if state then
		state.wearablesScanned = nil
	end
end

function CosmeticAbuse.NeedsScan(id)
	local state = PlayerCache.GetByID(id)
	return state == nil or not state.wearablesScanned
end

function CosmeticAbuse.ProcessPlayer(playerState)
	if not playerState or not playerState.pdata or not playerState.id then return end
	local id = tostring(playerState.id)

	-- Skip bots
	if id:sub(1, 4) == "BOT_" then return end

	if playerState.wearablesScanned then return end
	if not isEnabled() then return end
	if not Common.IsPlayerConnected() then return end
	if not Common.IsDebugEnabled() and playerState.isFriend then return end
	if playerState.pdata.isDormant then return end

	local disguiseClass = playerState.wrap:GetPropInt("m_iDisguiseTargetClass")
	if disguiseClass and disguiseClass > 0 then return end

	local isDebug = Common.IsLogCategoryEnabled("Cosmetics")
	local scanned = scanPlayerWearables(playerState.wrap:GetEntity(), id, isDebug)
	if not scanned then
		-- No wearables found - mark as scanned (F2P or no hats equipped)
		playerState.wearablesScanned = true
		return
	end

	playerState.wearablesScanned = true
	local illegal, reason = checkConflicts(id)
	if illegal then
		local localPlayer = entities.GetLocalPlayer()
		local isLocal = localPlayer and tostring(Common.GetSteamID64(localPlayer)) == id
		-- In debug mode, allow local player detection
		if not isLocal or Common.IsDebugEnabled() then
			local flagged = DetectorUtils.ApplyPlayerFlag(playerState, 0, Constants.Flags.CHEATER,
				"Equip region abuse: " .. (reason or "unknown conflict"))
			if isDebug then
				print(string.format("[CosmeticAbuse] %sFLAGGED: %s (flagsChanged=%s)",
					isLocal and "[LOCAL] " or "", reason or "unknown", tostring(flagged)))
			end
		end
	end
end

return CosmeticAbuse
