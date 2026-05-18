local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local G = require("Cheater_Detection.Utils.Globals")

local CosmeticAbuse = {}

local SCORE_GAIN = 6.0

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

-- equip_region AttributeDefinition resolved once at startup
local equipRegionAttrDef = nil
local schemaReady = false

-- defIndex -> equip_region string (or nil if no region / default wearable)
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

local function readPropEntity(ent, propName)
	local ok, value = pcall(ent.GetPropEntity, ent, propName)
	if not ok then return nil end
	return value
end

local function initSchema()
	if schemaReady then return end
	if not itemschema or not itemschema.GetAttributeDefinitionByName then return end

	local ok, attrDef = pcall(itemschema.GetAttributeDefinitionByName, "equip_region")
	if ok and attrDef then
		equipRegionAttrDef = attrDef
	end

	schemaReady = true
end

local function getItemRegion(defIndex)
	if regionCache[defIndex] ~= nil then
		return regionCache[defIndex]
	end
	-- Fallback: look up live if not cached (new items added at runtime)
	if not equipRegionAttrDef or not itemschema then return nil end
	local itemDef = itemschema.GetItemDefinitionByID(defIndex)
	if not itemDef or not itemDef.GetAttributes then return nil end
	local ok, attrs = pcall(itemDef.GetAttributes, itemDef)
	if not ok or type(attrs) ~= "table" then return nil end
	local region = attrs[equipRegionAttrDef]
	regionCache[defIndex] = (type(region) == "string" and region ~= "") and region or false
	return regionCache[defIndex] or nil
end

local function scanPlayerWearables(targetID)
	if not schemaReady then initSchema() end

	local data = { regions = {}, slotCounts = {} }

	local highest = entities.GetHighestEntityIndex()
	if type(highest) ~= "number" or highest <= 0 then return end

	for idx = 1, highest do
		local ent = entities.GetByIndex(idx)
		if ent and ent:IsValid() then
			local className = ent:GetClass()
			if type(className) == "string" and className:find("Wearable", 1, true) then
				local owner = readPropEntity(ent, "m_hOwnerEntity")
				if owner and owner:IsValid() and owner:IsPlayer() then
					local steamID64 = Common.GetSteamID64(owner)
					if tostring(steamID64) == targetID then
						local defIndex = readPropInt(ent, "m_iItemDefinitionIndex")
						local slot = readPropInt(ent, "m_nLoadoutSlot")
						if slot and slot >= 0 then
							data.slotCounts[slot] = (data.slotCounts[slot] or 0) + 1
						end
						if defIndex and defIndex > 0 then
							local region = getItemRegion(defIndex)
							if region then
								data.regions[region] = (data.regions[region] or 0) + 1
							end
						end
					end
				end
			end
		end
	end

	playerScanData[targetID] = data
	scannedPlayers[targetID] = true

	if G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug then
		local s = ""
		for slot, count in pairs(data.slotCounts) do s = s .. " s" .. slot .. "=" .. count end
		print("[CosmeticAbuse] id=" .. targetID .. " slots:{" .. s .. "}")
	end
	return true
end

local function checkConflicts(id)
	local data = playerScanData[id]
	if not data then return false, nil end

	local regions = data.regions
	local slotCounts = data.slotCounts

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

	-- 3. Total cosmetic wearables must not exceed 3
	local cosmeticSlots = {
		LOADOUT_POSITION_HEAD, LOADOUT_POSITION_MISC, LOADOUT_POSITION_MISC2, LOADOUT_POSITION_ACTION
	}
	local total = 0
	for _, slot in ipairs(cosmeticSlots) do
		total = total + (slotCounts[slot] or 0)
	end
	if total > 3 then
		return true, string.format("too many cosmetic wearables (%d)", total)
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

function CosmeticAbuse.ProcessPlayer(playerState, _cmd)
	if not playerState or not playerState.pdata or not playerState.id then return end
	if not Common.IsPlayerConnected() then return end
	if not isEnabled() then return end

	local isDebug = G.Menu and G.Menu.Advanced and G.Menu.Advanced.debug
	local id = tostring(playerState.id)

	if not isDebug and playerState.isFriend then return end

	local localPlayer = entities.GetLocalPlayer()
	local isLocalPlayer = localPlayer and tostring(Common.GetSteamID64(localPlayer)) == id

	if not isLocalPlayer and scannedPlayers[id] then return end

	local scanned = scanPlayerWearables(id)
	if not scanned then return end

	local illegal, reason = checkConflicts(id)
	if illegal and not isLocalPlayer then
		DetectorUtils.ApplyPlayerFlag(playerState, SCORE_GAIN, nil,
			"Equip region abuse: " .. (reason or "unknown conflict"))
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
