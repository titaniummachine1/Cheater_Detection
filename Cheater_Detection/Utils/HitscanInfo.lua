local HitscanInfo = {}

HitscanInfo.FIREMODE = {
	UNKNOWN = 0,
	HITSCAN = 1,
	PROJECTILE = 2,
	MELEE = 3,
	FLAME = 4,
}

local strFind = string.find

local PROJECTILE_SUBSTR = {
	"rocketlauncher",
	"grenadelauncher",
	"pipebomb",
	"compoundbow",
	"crossbow",
	"syringe",
	"cannon",
	"sticky",
	"flare",
	"particlecannon",
}

local MELEE_SUBSTR = {
	"knife",
	"bat",
	"bottle",
	"shovel",
	"wrench",
	"fists",
	"bonesaw",
	"sword",
	"club",
	"whip",
	"robotarm",
	"breakablesign",
	"breakable",
}

local FLAME_SUBSTR = {
	"flamethrower",
}

local HITSCAN_SUBSTR = {
	"sniper",
	"scatter",
	"shotgun",
	"pistol",
	"revolver",
	"smg",
	"minigun",
}

local function containsAny(haystack, substrings)
	if type(haystack) ~= "string" or haystack == "" then
		return false
	end
	for i = 1, #substrings do
		if strFind(haystack, substrings[i], 1, true) then
			return true
		end
	end
	return false
end

function HitscanInfo.Classify(attackerPly, weaponName, weaponID)
	local mode = HitscanInfo.FIREMODE.UNKNOWN
	local projType = nil
	local weaponClass = nil
	local weaponSpread = nil

	if weaponID == 54 or weaponID == 55 or weaponID == 68 then
		return false, nil, nil, nil, mode
	end

	if not attackerPly or not attackerPly.IsValid or not attackerPly:IsValid() then
		return false, nil, nil, nil, mode
	end

	local activeWeapon = attackerPly:GetPropEntity("m_hActiveWeapon")
	if not activeWeapon or not activeWeapon.IsValid or not activeWeapon:IsValid() then
		return false, nil, nil, nil, mode
	end

	weaponClass = activeWeapon.GetClass and activeWeapon:GetClass() or nil
	if activeWeapon.GetWeaponSpread then
		weaponSpread = activeWeapon:GetWeaponSpread()
	end

	local getProjType = activeWeapon.GetWeaponProjectileType
	if type(getProjType) == "function" then
		projType = activeWeapon:GetWeaponProjectileType()
		if projType == TF_PROJECTILE_BULLET then
			mode = HitscanInfo.FIREMODE.HITSCAN
		elseif projType ~= nil and projType ~= 0 then
			mode = HitscanInfo.FIREMODE.PROJECTILE
		end
	end

	if mode == HitscanInfo.FIREMODE.UNKNOWN then
		local classToken = tostring(weaponClass or ""):lower()
		local nameToken = tostring(weaponName or ""):lower()

		if containsAny(classToken, MELEE_SUBSTR) or containsAny(nameToken, MELEE_SUBSTR) then
			mode = HitscanInfo.FIREMODE.MELEE
		elseif containsAny(classToken, FLAME_SUBSTR) or containsAny(nameToken, FLAME_SUBSTR) then
			mode = HitscanInfo.FIREMODE.FLAME
		elseif strFind(nameToken, "tf_projectile", 1, true) or containsAny(classToken, PROJECTILE_SUBSTR)
			or containsAny(nameToken, PROJECTILE_SUBSTR) then
			mode = HitscanInfo.FIREMODE.PROJECTILE
		elseif containsAny(classToken, HITSCAN_SUBSTR) or containsAny(nameToken, HITSCAN_SUBSTR) then
			mode = HitscanInfo.FIREMODE.HITSCAN
		end
	end

	local isHitscan = mode == HitscanInfo.FIREMODE.HITSCAN
	return isHitscan, weaponClass, weaponSpread, projType, mode
end

return HitscanInfo
