--[[ Misc/SniperDotAngle.lua
     Sniper laser-dot real-angle decode  (Rijin-derived: detect_sniper_dot)

     Every CreateMove tick we iterate all CTFSniperDot entities.  Each dot is
     owned by a sniper.  We back-calculate the sniper's TRUE pitch from the
     dot's world position relative to the sniper's eye position using basic
     trig (atan2).  If the sniper's networked pitch is ±90° (fake pitch AA)
     but the dot gives us a sane real pitch, we have a zero-false-positive
     confirmation of pitch anti-aim, and we hard-flag them.

     The module self-registers its CreateMove handler via Events so it is
     automatically active whenever loaded from Main.lua.
]]

local Common    = require("Cheater_Detection.Utils.Common")
local Constants = require("Cheater_Detection.Core.constants")
local Evidence  = require("Cheater_Detection.Core.Evidence_system")
local Events    = require("Cheater_Detection.Core.Events")
local G         = require("Cheater_Detection.Utils.Globals")
local MathUtils = require("Cheater_Detection.Utils.MathUtils")
local PlayerCache = require("Cheater_Detection.Core.player_cache")

local SniperDotAngle = {}

-- ── constants ──────────────────────────────────────────────────────────────
local DOT_CLASSNAME      = "CTFSniperDot"
local MAX_LEGAL_PITCH    = 89.30        -- same cap as antiaim.lua
local FAKE_PITCH_MIN     = 89.0         -- networked pitch magnitude we call "fake"
local EVIDENCE_WEIGHT    = 15.0         -- strong signal – dot doesn't lie
local EVIDENCE_COOLDOWN  = 4.0          -- seconds between additions per player

-- Track last evidence time per steamID
local lastEvidenceTime = {}

-- ── helpers ────────────────────────────────────────────────────────────────
local function getNetworkedPitch(ent)
	local p = ent:GetPropFloat("m_angEyeAngles[0]")
	if type(p) == "number" then return p end
	local v = ent:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
	if v then return v.x end
	v = ent:GetPropVector("m_angEyeAngles[0]")
	if v then return v.x end
	return nil
end

local function getEyePos(ent)
	local origin = ent:GetAbsOrigin()
	if not origin then return nil end
	local vo = ent:GetPropVector("localdata", "m_vecViewOffset[0]")
	if vo then
		return Vector3(origin.x + vo.x, origin.y + vo.y, origin.z + vo.z)
	end
	return Vector3(origin.x, origin.y, origin.z + 72)
end

-- ── main scan ──────────────────────────────────────────────────────────────
local function scanDots()
	if not (G.Menu and G.Menu.Advanced and G.Menu.Advanced.AntiAim) then return end
	if not Common.IsPlayerConnected() then return end

	local isDebug = Common.IsDebugEnabled()
	local now     = globals.RealTime()

	local dots = entities.FindByClass(DOT_CLASSNAME)
	if not dots then return end

	for _, dot in pairs(dots) do
		if not dot or not dot:IsValid() then goto continue end
		if dot:IsDormant()              then goto continue end

		local dotPos = dot:GetAbsOrigin()
		if not dotPos then goto continue end

		-- Owner handle: m_hOwnerEntity
		local owner = dot:GetPropEntity("m_hOwnerEntity")
		if not owner or not owner:IsValid() then goto continue end
		if owner:IsDormant() or not owner:IsAlive() then goto continue end

		-- Skip local player's own dot
		local localPlayer = entities.GetLocalPlayer()
		if localPlayer and owner:GetIndex() == localPlayer:GetIndex() then goto continue end

		-- Get steamID via PlayerCache
		local steamID = Common.GetSteamID64(owner)
		if not steamID or not steamID:match("^7656119%d+$") then goto continue end

		-- Skip friends (unless debug)
		if not isDebug and Common.IsFriend(owner) then goto continue end

		-- Only bother if this player shows a fake networked pitch
		local netPitch = getNetworkedPitch(owner)
		if not netPitch then goto continue end

		local absNetPitch = math.abs(netPitch)
		if absNetPitch < FAKE_PITCH_MIN then goto continue end

		-- Back-calculate real pitch from dot world position
		local eyePos = getEyePos(owner)
		if not eyePos then goto continue end

		local realPitch, _ = MathUtils.angleToXYZ(eyePos, dotPos.x, dotPos.y, dotPos.z)

		-- Sanity: real pitch must be legal (dot position should give a sane angle)
		if type(realPitch) ~= "number" then goto continue end
		local absRealPitch = math.abs(realPitch)
		if absRealPitch > MAX_LEGAL_PITCH then goto continue end

		-- Confirmed: networked pitch is ±90° but dot says otherwise → pitch AA
		local last = lastEvidenceTime[steamID] or 0
		if (now - last) < EVIDENCE_COOLDOWN then goto continue end
		lastEvidenceTime[steamID] = now

		Evidence.AddEvidence(steamID, "anti_aim", EVIDENCE_WEIGHT)

		if isDebug then
			print(string.format(
				"[SniperDot] %s: net_pitch=%.1f real_pitch=%.1f → pitch AA confirmed",
				steamID, netPitch, realPitch
			))
		end

		::continue::
	end
end

-- ── event wiring ───────────────────────────────────────────────────────────
Events.Register("CreateMove", "SniperDot_Scan", function(_cmd)
	local ok, err = pcall(scanDots)
	if not ok then
		print("[SniperDot] error: " .. tostring(err))
	end
end)

Events.Subscribe("OnPlayerDisconnect", function(id)
	lastEvidenceTime[id] = nil
end)

return SniperDotAngle
