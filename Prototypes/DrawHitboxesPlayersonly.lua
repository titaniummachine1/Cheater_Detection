local WORLD2SCREEN = client.WorldToScreen
local LINE = draw.Line
local COLOR = draw.Color

local function DrawAxisLines(vecForward, vecUp, vecRight, vecOrigin, flScale)
	local p0 = WORLD2SCREEN(vecOrigin)
	if not p0 then
		return
	end

	local p1 = WORLD2SCREEN(vecForward * flScale + vecOrigin)
	local p2 = WORLD2SCREEN(vecUp * flScale + vecOrigin)
	local p3 = WORLD2SCREEN(vecRight * flScale + vecOrigin)

	if p1 then
		COLOR(255, 0, 0, 255)
		LINE(p0[1], p0[2], p1[1], p1[2])
	end

	if p2 then
		COLOR(0, 255, 0, 255)
		LINE(p0[1], p0[2], p2[1], p2[2])
	end

	if p3 then
		COLOR(0, 0, 255, 255)
		LINE(p0[1], p0[2], p3[1], p3[2])
	end
end

local function GetEntityHitboxes(pEntity)
	local model = pEntity:GetModel()
	if not model then
		return {}
	end

	local studiomodel = models.GetStudioModel(model)
	if not studiomodel then
		return {}
	end

	-- Try different hitbox sets to find all hitboxes including hips
	local hitboxSet = pEntity:GetPropInt("m_nHitboxSet") or 0
	local setHitboxes = studiomodel:GetHitboxSet(hitboxSet)

	-- If no hitboxes found, try set 0 (default)
	if not setHitboxes then
		setHitboxes = studiomodel:GetHitboxSet(0)
	end
	if not setHitboxes then
		return {}
	end

	local flModelScale = pEntity:GetPropFloat("m_flModelScale") or 1
	local aBones = pEntity:SetupBones(0x7ff00, globals.CurTime())
	local aReturned = {}

	local hitboxList = setHitboxes:GetHitboxes()
	for _, hitbox in pairs(hitboxList) do
		local mat = aBones[hitbox:GetBone()]
		if mat then -- aBones doesn't have an entry at index 0 so it can fail for some hitboxes.
			-- Debug: Print hitbox name
			local hitboxName = hitbox:GetName() or "Unknown"
			if string.find(hitboxName:lower(), "hip") or string.find(hitboxName:lower(), "pelvis") then
				print("Found hip/pelvis hitbox:", hitboxName)
			end
			local vecMins = hitbox:GetBBMin() * flModelScale
			local vecMaxs = hitbox:GetBBMax() * flModelScale

			DrawAxisLines(
				Vector3(mat[1][1], mat[2][1], mat[3][1]),
				Vector3(mat[1][2], mat[2][2], mat[3][2]),
				Vector3(mat[1][3], mat[2][3], mat[3][3]),
				Vector3(mat[1][4], mat[2][4], mat[3][4]),
				10
			)

			local x11, x12, x13 =
				mat[1][4] + vecMins.x * mat[1][1], mat[2][4] + vecMins.x * mat[2][1], mat[3][4] + vecMins.x * mat[3][1]
			local x21, x22, x23 =
				mat[1][4] + vecMaxs.x * mat[1][1], mat[2][4] + vecMaxs.x * mat[2][1], mat[3][4] + vecMaxs.x * mat[3][1]
			local y11, y12, y13 = vecMins.y * mat[1][2], vecMins.y * mat[2][2], vecMins.y * mat[3][2]
			local y21, y22, y23 = vecMaxs.y * mat[1][2], vecMaxs.y * mat[2][2], vecMaxs.y * mat[3][2]
			local z11, z12, z13 = vecMins.z * mat[1][3], vecMins.z * mat[2][3], vecMins.z * mat[3][3]
			local z21, z22, z23 = vecMaxs.z * mat[1][3], vecMaxs.z * mat[2][3], vecMaxs.z * mat[3][3]

			aReturned[#aReturned + 1] = {
				Vector3(x11 + y11 + z11, x12 + y12 + z12, x13 + y13 + z13),
				Vector3(x21 + y11 + z11, x22 + y12 + z12, x23 + y13 + z13),
				Vector3(x11 + y21 + z11, x12 + y22 + z12, x13 + y23 + z13),
				Vector3(x21 + y21 + z11, x22 + y22 + z12, x23 + y23 + z13),
				Vector3(x11 + y11 + z21, x12 + y12 + z22, x13 + y13 + z23),
				Vector3(x21 + y11 + z21, x22 + y12 + z22, x23 + y13 + z23),
				Vector3(x11 + y21 + z21, x12 + y22 + z22, x13 + y23 + z23),
				Vector3(x21 + y21 + z21, x22 + y22 + z22, x23 + y23 + z23),
			}
		end
	end

	return aReturned
end

local function DrawHitboxes()
	local pLocalPlayer = entities.GetLocalPlayer()
	local iLocalPlayerIndex = pLocalPlayer:GetIndex()

	-- Use entities.FindByClass for reliable player iteration
	local players = entities.FindByClass("CTFPlayer")
	if not players then
		return
	end

	local playerCount = 0
	for _, pPlayer in pairs(players) do
		if pPlayer and pPlayer:IsAlive() and not pPlayer:IsDormant() then
			playerCount = playerCount + 1
			local hitboxes = GetEntityHitboxes(pPlayer)
			if hitboxes and #hitboxes > 0 then
				COLOR(255, 0, 255, 255)
				for _, aVerts in pairs(hitboxes) do
					if #aVerts == 8 then
						local p1 = WORLD2SCREEN(aVerts[1])
						local p2 = WORLD2SCREEN(aVerts[2])
						local p3 = WORLD2SCREEN(aVerts[3])
						local p4 = WORLD2SCREEN(aVerts[4])
						local p5 = WORLD2SCREEN(aVerts[5])
						local p6 = WORLD2SCREEN(aVerts[6])
						local p7 = WORLD2SCREEN(aVerts[7])
						local p8 = WORLD2SCREEN(aVerts[8])

						if p1 and p2 and p3 and p4 and p5 and p6 and p7 and p8 then
							LINE(p1[1], p1[2], p2[1], p2[2])
							LINE(p1[1], p1[2], p3[1], p3[2])
							LINE(p1[1], p1[2], p5[1], p5[2])
							LINE(p2[1], p2[2], p4[1], p4[2])
							LINE(p2[1], p2[2], p6[1], p6[2])
							LINE(p3[1], p3[2], p4[1], p4[2])
							LINE(p3[1], p3[2], p7[1], p7[2])
							LINE(p4[1], p4[2], p8[1], p8[2])
							LINE(p5[1], p5[2], p6[1], p6[2])
							LINE(p5[1], p5[2], p7[1], p7[2])
							LINE(p6[1], p6[2], p8[1], p8[2])
							LINE(p7[1], p7[2], p8[1], p8[2])
						end
					end
				end
			end
		end
	end
end

-- Register the Draw callback properly
callbacks.Unregister("Draw", "DrawHitboxes_Callback")
callbacks.Register("Draw", "DrawHitboxes_Callback", DrawHitboxes)
