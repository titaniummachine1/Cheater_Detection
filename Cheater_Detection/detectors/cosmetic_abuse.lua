local Common = require("Cheater_Detection.Utils.Common")
local DetectorUtils = require("Cheater_Detection.Utils.DetectorUtils")
local G = require("Cheater_Detection.Utils.Globals")

local CosmeticAbuse = {}

local SCAN_INTERVAL_TICKS = 66
local CHECK_INTERVAL_TICKS = 66
local SCORE_GAIN = 6.0

local lastGlobalScanTick = -999999
local scanGen = 0

local lastCheckTick = {}
local entryGen = {}
local headCount = {}
local miscCount = {}
local misc2Count = {}
local actionCount = {}

local function readPropInt(ent, propName)
	local ok, value = pcall(ent.GetPropInt, ent, propName)
	if not ok or type(value) ~= "number" then
		return nil
	end
	return value
end

local function readPropEntity(ent, propName)
	local ok, value = pcall(ent.GetPropEntity, ent, propName)
	if not ok then
		return nil
	end
	return value
end

local function scanWearables(curTick)
	if not itemschema or type(itemschema.GetItemDefinitionByID) ~= "function" then
		return
	end

	scanGen = scanGen + 1
	lastGlobalScanTick = curTick

	local highest = entities.GetHighestEntityIndex()
	if type(highest) ~= "number" or highest <= 0 then
		return
	end

	for idx = 1, highest do
		local ent = entities.GetByIndex(idx)
		if ent and ent:IsValid() then
			local className = ent:GetClass()
			if type(className) == "string" and className:find("Wearable", 1, true) then
				local owner = readPropEntity(ent, "m_hOwnerEntity")
				if owner and owner:IsValid() and owner:IsPlayer() then
					local steamID64 = Common.GetSteamID64(owner)
					if steamID64 then
						local id = tostring(steamID64)
						if entryGen[id] ~= scanGen then
							entryGen[id] = scanGen
							headCount[id] = 0
							miscCount[id] = 0
							misc2Count[id] = 0
							actionCount[id] = 0
						end

						local defIndex = readPropInt(ent, "m_iItemDefinitionIndex")
						if defIndex and defIndex > 0 then
							local itemDef = itemschema.GetItemDefinitionByID(defIndex)
							if itemDef and type(itemDef.GetLoadoutSlot) == "function" then
								local slot = itemDef:GetLoadoutSlot()
								if slot == LOADOUT_POSITION_HEAD then
									headCount[id] = headCount[id] + 1
								elseif slot == LOADOUT_POSITION_MISC then
									miscCount[id] = miscCount[id] + 1
								elseif slot == LOADOUT_POSITION_MISC2 then
									misc2Count[id] = misc2Count[id] + 1
								elseif slot == LOADOUT_POSITION_ACTION then
									actionCount[id] = actionCount[id] + 1
								end
							end
						end
					end
				end
			end
		end
	end
end

local function isEnabled()
	local menu = G.Menu
	local advanced = menu and menu.Advanced
	if not advanced then
		return false
	end
	return advanced.Cosmetics == true
end

local function getCounts(id)
	if entryGen[id] ~= scanGen then
		return 0, 0, 0, 0
	end
	return headCount[id] or 0, miscCount[id] or 0, misc2Count[id] or 0, actionCount[id] or 0
end

function CosmeticAbuse.ProcessPlayer(playerState)
	if not playerState or not playerState.id then
		return
	end
	if not isEnabled() then
		return
	end

	local id = tostring(playerState.id)
	local curTick = globals.TickCount()

	if lastCheckTick[id] and (curTick - lastCheckTick[id]) < CHECK_INTERVAL_TICKS then
		return
	end
	lastCheckTick[id] = curTick

	if (curTick - lastGlobalScanTick) >= SCAN_INTERVAL_TICKS then
		scanWearables(curTick)
	end

	local head, misc, misc2, action = getCounts(id)
	local total = head + misc + misc2 + action

	local illegal = false
	if head > 1 then
		illegal = true
	elseif action > 1 then
		illegal = true
	elseif misc > 2 then
		illegal = true
	elseif misc2 > 1 then
		illegal = true
	elseif total > 4 then
		illegal = true
	end

	if illegal then
		DetectorUtils.ApplyPlayerFlag(playerState, SCORE_GAIN, nil, "Suspicious cosmetics (extra wearable slots)")
	end
end

return CosmeticAbuse

