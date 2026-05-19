-- Targeted items_game.txt scanner for equip_region data.
-- Avoids building a full VDF tree (file is ~20MB); instead does a single
-- depth-tracked line pass, extracting only what we need.

local VDFParser = {}

local equipRegionCache = {}
local loaded = false

local function findItemsGamePath()
	local _, fullPath = filesystem.CreateDirectory([[tf\scripts\items]])
	if type(fullPath) ~= "string" then
		print("[VDFParser] filesystem API unavailable")
		return nil
	end
	local sep = package.config:sub(1, 1)
	local path = fullPath .. sep .. "items_game.txt"
	local f = io.open(path, "r")
	if not f then
		print("[VDFParser] items_game.txt not found at: " .. path)
		return nil
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
	if not path then return end

	print("[VDFParser] Scanning items_game.txt for equip_region data...")
	local count = scanEquipRegions(path)
	print(string.format("[VDFParser] Done: %d equip_region entries loaded", count))
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
