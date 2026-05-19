local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local G = require("Cheater_Detection.Utils.Globals")
local Constants = require("Cheater_Detection.Core.constants")
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

-- Load items_game.txt data once at startup
VDFParser.LoadItemsGame()

-- defIndex -> equip_region string (or false if no region)
local regionCache = {}

-- per-player scan results: id -> { regions = {region->count}, slotCounts = {slot->count} }
-- nil = not yet scanned, false = scanned clean, table = conflict data
local playerScanData = {}
-- ids that have been fully scanned this session; cleared on class change/spawn
local scannedPlayers = {}

local function readPropInt(ent, propName)
	local ok, value = pcall(ent.GetPropInt, ent, propName)
	if not ok or type(value) ~= "number" then return nil end
	return value
end

local function getItemName(defIndex)
	if not itemschema then return nil end
	local itemDef = itemschema.GetItemDefinitionByID(defIndex)
	if not itemDef then return nil end
	local ok, name = pcall(itemDef.GetName, itemDef)
	return (ok and type(name) == "string" and name ~= "") and name or nil
end

local function getItemRegion(defIndex)
	if regionCache[defIndex] ~= nil then
		return regionCache[defIndex] or nil
	end
	-- Use VDF parser to get equip_region from items_game.txt
	local region = VDFParser.GetEquipRegion(defIndex)
	if region then
		regionCache[defIndex] = region
		return region
	end
	regionCache[defIndex] = false
	return nil
end

local function findPlayerByID(targetID)
	local players = entities.FindByClass("CTFPlayer")
	for _, ent in pairs(players) do
		if ent:IsValid() then
			local sid = Common.GetSteamID64(ent)
			if tostring(sid) == targetID then return ent end
		end
	end
	return nil
end

local function scanPlayerWearables(targetID)
	local player = findPlayerByID(targetID)
	if not player then return false end

	local playerIdx = player:GetIndex()
	local data = { regions = {}, slotNames = {} }
	local seenEntIndex = {}
	local itemNum = 0

	local function processWearable(wearable)
		if not wearable or not wearable:IsValid() then return end
		local entIdx = wearable:GetIndex()
		if seenEntIndex[entIdx] then return end
		seenEntIndex[entIdx] = true
		itemNum = itemNum + 1

		local defIndex = readPropInt(wearable, "m_iItemDefinitionIndex")
		if defIndex and defIndex > 0 then
			local region = getItemRegion(defIndex)
			if region then
				data.regions[region] = (data.regions[region] or 0) + 1
			end
			local iname = getItemName(defIndex)
			data.slotNames[itemNum] = string.format("%s [%d]%s",
				iname or "?", defIndex, region and (" region=" .. region) or "")
		else
			data.slotNames[itemNum] = string.format("? [defIndex=%s entIdx=%d]",
				tostring(defIndex), entIdx)
		end
	end

	local function isOwnedByPlayer(wearable)
		local ok, owner = pcall(wearable.GetPropEntity, wearable, "m_hOwnerEntity")
		if ok and owner and owner:IsValid() and owner:GetIndex() == playerIdx then
			return true
		end
		local ok2, parent = pcall(wearable.GetPropEntity, wearable, "m_hMoveParent")
		if ok2 and parent and parent:IsValid() and parent:GetIndex() == playerIdx then
			return true
		end
		return false
	end

	-- Primary: scan ALL live CTFWearable entities filtered by owner.
	-- This catches extra entities that the slot system never returns.
	local allWearables = entities.FindByClass("CTFWearable")
	for _, wearable in pairs(allWearables) do
		if wearable:IsValid() and isOwnedByPlayer(wearable) then
			processWearable(wearable)
		end
	end

	-- Secondary: loadout slots 7-12, catches anything the entity scan missed.
	for slot = 7, 12 do
		local ok, item = pcall(player.GetEntityForLoadoutSlot, player, slot)
		if ok and item then
			processWearable(item)
		end
	end

	data.totalWearables = itemNum
	playerScanData[targetID] = data
	scannedPlayers[targetID] = true

	if G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug then
		local parts = { string.format("[CosmeticAbuse] id=%s wearables=%d", targetID, itemNum) }
		for i, label in pairs(data.slotNames) do
			parts[#parts + 1] = string.format("  item%d: %s", i, label)
		end
		print(table.concat(parts, "\n"))
	end

	return true
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

function CosmeticAbuse.InvalidatePlayer(id)
	scannedPlayers[id] = nil
	playerScanData[id] = nil
end

function CosmeticAbuse.NeedsScan(id)
	return scannedPlayers[id] == nil
end

function CosmeticAbuse.ProcessPlayer(playerState, _cmd)
	if not playerState or not playerState.pdata or not playerState.id then return end
	if not Common.IsPlayerConnected() then return end
	if not isEnabled() then return end

	local isDebug = G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug
	local id = tostring(playerState.id)

	if not isDebug and playerState.isFriend then return end

	local localPlayer = entities.GetLocalPlayer()
	local isLocalPlayer = localPlayer and tostring(Common.GetSteamID64(localPlayer)) == id

	if scannedPlayers[id] then return end

	local scanned = scanPlayerWearables(id)
	if not scanned then return end

	local illegal, reason = checkConflicts(id)
	if illegal then
		if isLocalPlayer and not isDebug then
			-- Skip flagging local player in normal mode
			return
		end
		-- Hard detection: duplicate equip_region or >3 wearables is 100% impossible
		local flagged = DetectorUtils.ApplyPlayerFlag(playerState, 0, Constants.Flags.CHEATER,
			"Equip region abuse: " .. (reason or "unknown conflict"))
		if isDebug then
			print(string.format("[CosmeticAbuse] %sFLAGGED: %s (flagsChanged=%s)",
				isLocalPlayer and "[LOCAL] " or "", reason or "unknown", tostring(flagged)))
		end
	end
end

callbacks.Register("FireGameEvent", function(event)
	if not event then return end
	local name = event:GetName()
	if name ~= "player_changeclass" and name ~= "player_spawn" then return end
	local userID = event:GetInt("userid")
	if not userID then return end
	local ent = entities.GetByUserID(userID)
	if not ent or not ent:IsValid() then return end
	local steamID64 = Common.GetSteamID64(ent)
	if steamID64 then
		CosmeticAbuse.InvalidatePlayer(tostring(steamID64))
	end
end)

return CosmeticAbuse
