-- Targeted items_game.txt scanner for equip_region data.
-- Avoids building a full VDF tree (file is ~20MB); instead does a single
-- depth-tracked line pass, extracting only what we need.

local VDFParser = {}

local equipRegionCache = {}
local loaded = false

local function findItemsGamePath()
	-- engine.GetGameDir() returns e.g. "C:\Steam\steamapps\common\Team Fortress 2\tf"
	local gameDir = engine.GetGameDir()
	if type(gameDir) ~= "string" or gameDir == "" then
		error("[VDFParser] FATAL: engine.GetGameDir() returned nothing — can't locate items_game.txt")
	end
	local sep = package.config:sub(1, 1)
	local path = gameDir .. sep .. "scripts" .. sep .. "items" .. sep .. "items_game.txt"
	print("[VDFParser] Looking for items_game.txt at: " .. path)
	local f = io.open(path, "r")
	if not f then
		error("[VDFParser] FATAL: items_game.txt not found at: " .. path)
	end
	f:close()
	return path
end

-- Single-pass line scanner. Tracks VDF nesting depth to find:
--   depth 1 : "items_game" root block
--   depth 2 : "items" block
--   depth 3 : individual item block (key is the defIndex string)
--   depth 3+: "equip_region" "value"  OR  "equip_regions" { "region" "1" }
local function scanEquipRegions(path)
	local f = io.open(path, "r")
	if not f then return 0 end

	local depth          = 0
	local pendingKey     = nil -- key whose "{" hasn't arrived yet
	local inItems        = false -- inside the "items" block (depth==2)
	local currentDefIdx  = nil -- numeric defIndex of the current item
	local inEquipRegions = false -- inside an "equip_regions" sub-block
	local equipDepth     = nil -- depth at which equip_regions opened
	local count          = 0

	for line in f:lines() do
		local trimmed = line:match("^%s*(.-)%s*$")

		if trimmed == "{" then
			depth = depth + 1

			if pendingKey == "items" and depth == 2 then
				inItems = true
			elseif inItems and depth == 3 and pendingKey then
				currentDefIdx = tonumber(pendingKey)
			elseif inItems and currentDefIdx and pendingKey == "equip_regions" then
				inEquipRegions = true
				equipDepth     = depth
			end
			pendingKey = nil
		elseif trimmed == "}" then
			if inEquipRegions and depth == equipDepth then
				inEquipRegions = false
				equipDepth     = nil
			end
			if inItems and depth == 3 then
				currentDefIdx = nil
			end
			if inItems and depth == 2 then
				inItems = false
			end
			depth = depth - 1
		else
			-- Try key-value pair on the same line: "key"  "value"
			local k, v = trimmed:match('^"([^"]+)"%s+"([^"]+)"')
			if k and v then
				if inItems and currentDefIdx then
					if k == "equip_region" and not equipRegionCache[currentDefIdx] then
						equipRegionCache[currentDefIdx] = v
						count = count + 1
					elseif inEquipRegions and not equipRegionCache[currentDefIdx] then
						-- First key inside equip_regions block is the primary region name
						equipRegionCache[currentDefIdx] = k
						count = count + 1
					end
				end
				pendingKey = nil
			else
				-- Single quoted token = key for the next block
				pendingKey = trimmed:match('^"([^"]+)"%s*$')
			end
		end
	end

	f:close()
	return count
end

function VDFParser.LoadItemsGame()
	if loaded then return end
	loaded = true

	local path = findItemsGamePath()
	if not path then
		error("[VDFParser] FATAL: Could not find items_game.txt — cosmetic detection is broken!")
	end

	print("[VDFParser] Scanning items_game.txt for equip_region data...")
	local count = scanEquipRegions(path)
	if count == 0 then
		error("[VDFParser] FATAL: Parsed items_game.txt but found 0 equip_region entries — parser is broken, fix it!")
	end
	print(string.format("[VDFParser] OK: %d equip_region entries loaded", count))
end

function VDFParser.GetEquipRegion(defIndex)
	if not loaded then
		VDFParser.LoadItemsGame()
	end
	return equipRegionCache[defIndex]
end

function VDFParser.Reload()
	loaded = false
	for k in pairs(equipRegionCache) do equipRegionCache[k] = nil end
	VDFParser.LoadItemsGame()
end

return VDFParser
