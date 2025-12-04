--[[
  Made by Navet
--]]

---@diagnostic disable: cast-local-type

local settings = {

	--- both recharging and warp checks these
	both = {
		check_aimbot_target = true,
		ignore_spectators = true,
	},

	warp = {
		key = gui.GetValue("double tap key"), --- you can change to E_ButtonCode.KEY_R for example

		delay = 0, --- how many ticks to wait to warp again (0 means as soon as possible)

		while_shooting = true, --- if its disabled, we stop warping until you or aimbot stop shooting
		standing_still = false,
	},

	recharge = {
		key = gui.GetValue("force recharge key"),

		delay = 0, --- how many ticks to wait before recharging again (0 means as soon as possible)

		while_shooting = false,
		standing_still = true,
	},

	passive_recharge = {
		enabled = true,
		while_dead = true,
		time = 1, --- ticks between each passive recharge (use game ticks, 66 ≈ 1 second)
		toggle_key = E_ButtonCode.KEY_R,

		randomized = {
			enabled = true, --- randomizes when we'll recharge and ignores passive_recharge.time. Values are in ticks.
			min_time = 20,
			max_time = 200,
		},
	},

	desync = { --- desync your charged ticks and recharge
		--- thought this was funny at 4 am so yeah idk what im doing
		enabled = true,
		key = E_ButtonCode.KEY_F,
	},

	burst_mode = {
		enabled = false, --- if true, sends ALL accumulated ticks at once instead of one per warp
		key = E_ButtonCode.KEY_G, --- separate key for burst warp
	},
}
--- end of settings
--- dont change stuff below this line pls

local charged_ticks = 0 // 1
local next_passive_recharge_tick = globals.TickCount() + settings.passive_recharge.time // 1
local last_pressed_tick = 0 // 1
local maxticks = 0 // 1

local warping, recharging = false, false
local burst_warping = false
local shooting = false
local localplayer_alive = false
local localplayer_velocity = 0
local localplayer_isRed = false
local spectated = false

local screenX <const>, screenY <const> = draw:GetScreenSize()
local centerX <const>, centerY <const> = math.floor(screenX / 2), math.floor(screenY / 2)
local unformatted_text <const> = "%i / %i"
local font <const> = draw.CreateFont("TF2 BUILD", 16, 1000)

local warning_string = "Disabled double tap and dash, you can recharge with antiaim"

local NEW_COMMANDS_SIZE <const> = 4 // 1
local BACKUP_COMMANDS_SIZE <const> = 3 // 1

local SIGNONSTATE_TYPE <const> = 6 // 1
local CLC_MOVE_TYPE <const> = 9 // 1

local old_tickbase = 0

-- Tracks the previous choked command count so we can salvage only "new" chokes
local last_choked_commands = 0 // 1

--- disable lbox's tick shifting stuff
gui.SetValue("double tap", "none")
gui.SetValue("dash move key", 0)

---@param ... string
local function ChatPrintf(...)
	local args = { ... }
	for i = 1, #args do
		client.ChatPrintf(args[i])
	end
end

if not clientstate:GetNetChannel() then
	printc(255, 150, 150, 255, warning_string)
else
	ChatPrintf(warning_string)
end

local function clamp(value, min, max)
	return math.min(math.max(value, min), max)
end

local function clc_Move(num_commands)
	num_commands = num_commands or 2 -- default to 2 for single warp
	local t = { new_commands = num_commands, backup_commands = 1, buffer = BitBuffer() }

	function t:init()
		self.buffer:Reset()
		self.buffer:WriteInt(self.new_commands, NEW_COMMANDS_SIZE)
		self.buffer:WriteInt(self.backup_commands, BACKUP_COMMANDS_SIZE)
		self.buffer:Reset()
	end

	setmetatable(t, {
		__close = function(this)
			this.buffer:Delete()
			this.buffer = nil
			this.new_commands = nil
			this.backup_commands = nil
		end,
	})

	return t
end

local function GetMaxServerTicks()
	local sv_maxusrcmdprocessticks = client.GetConVar("sv_maxusrcmdprocessticks")
	if sv_maxusrcmdprocessticks then
		return sv_maxusrcmdprocessticks > 0 and sv_maxusrcmdprocessticks or 9999999
	end
	return 24
end

local function CanChokeTick()
	return clientstate:GetChokedCommands() < maxticks
end

local function CanShiftTick()
	return clientstate:GetChokedCommands() == 0
end

--- Resets the variables to their default state when joining a new server
---@param msg NetMessage
local function HandleJoinServers(msg)
	if clientstate:GetClientSignonState() == E_SignonState.SIGNONSTATE_SPAWN then
		maxticks = GetMaxServerTicks()
		charged_ticks = 0
		next_passive_recharge_tick = globals.TickCount() + settings.passive_recharge.time
		last_pressed_tick = 0
		warping, recharging = false, false
		shooting = false
		localplayer_alive = false
		localplayer_velocity = 0
	end
end

local function CanRecharge()
	if charged_ticks >= maxticks then
		return false
	end

	if shooting and settings.recharge.while_shooting then
		return false
	end

	if not CanChokeTick() then
		return false
	end

	if globals.TickCount() % (settings.recharge.delay + 1) ~= 0 then
		return false
	end

	return true
end

--- Returns true if we passively recharged, and false if we should try the normal recharge
---@param msg NetMessage
local function HandlePassiveRecharge(msg)
	if not settings.passive_recharge.enabled then
		return false
	end
	if settings.passive_recharge.while_dead and not localplayer_alive then
		charged_ticks = charged_ticks + 1
		return true
	end
	-- If the player is standing completely still, instantly refill all available ticks.
	-- A small threshold (<= 0.1) is used instead of exactly 0 to avoid float precision edge-cases.
	if localplayer_velocity <= 0.1 then
		charged_ticks = maxticks
		return true
	end
	if globals.TickCount() >= next_passive_recharge_tick then
		charged_ticks = charged_ticks + 1
		local time = settings.passive_recharge.randomized.enabled
				and engine.RandomInt(
					settings.passive_recharge.randomized.min_time,
					settings.passive_recharge.randomized.max_time
				)
			or settings.passive_recharge.time
		next_passive_recharge_tick = globals.TickCount() + time
		return true
	end
	return false
end

--- Returns true for a successful recharge, or false if we shouldn't
---@param msg NetMessage
local function HandleRecharge(msg)
	--- lmaobox is choking all the ticks available :(
	if
		not CanChokeTick()
		or charged_ticks >= maxticks
		or (shooting and not settings.recharge.while_shooting)
		or (localplayer_velocity <= 0 and not settings.recharge.standing_still)
		or (not settings.both.ignore_spectators and spectated)
	then
		return false
	end

	if settings.passive_recharge.while_dead and not localplayer_alive then
		charged_ticks = charged_ticks + 1
		return true
	end

	if HandlePassiveRecharge(msg) then
		return true
	end

	if CanRecharge() and recharging then
		charged_ticks = charged_ticks + 1
		return true
	end

	return false
end

--- Returns true if the warp was successful
---@param msg NetMessage
local function HandleWarp(msg)
	if
		(shooting and not settings.warp.while_shooting)
		or (not settings.warp.standing_still and localplayer_velocity <= 0)
		or (spectated and not settings.both.ignore_spectators)
	then
		return true
	end

	if
		localplayer_alive
		and charged_ticks > 0
		and CanShiftTick()
		and globals.TickCount() % (settings.warp.delay + 1) == 0
	then
		local moveMsg <close> = clc_Move()
		moveMsg:init()
		msg:ReadFromBitBuffer(moveMsg.buffer)
		charged_ticks = charged_ticks - 1
		return true
	end
	return false
end

--- Returns true if the burst warp was successful (sends ALL accumulated ticks at once)
---@param msg NetMessage
local function HandleBurstWarp(msg)
	if
		(shooting and not settings.warp.while_shooting)
		or (not settings.warp.standing_still and localplayer_velocity <= 0)
		or (spectated and not settings.both.ignore_spectators)
	then
		return true
	end

	if
		localplayer_alive
		and charged_ticks > 0
		and CanShiftTick()
		and globals.TickCount() % (settings.warp.delay + 1) == 0
	then
		-- Send ALL accumulated ticks at once for instant melee/movement
		local commands_to_send = charged_ticks + 1 -- +1 for the current tick
		local moveMsg <close> = clc_Move(commands_to_send)
		moveMsg:init()

		-- EXAMPLE: Force +attack on all burst ticks for instant melee
		-- You can modify any button bits here before sending
		-- Uncomment these lines to auto-attack during burst:
		-- local usercmd = input.GetUserCmd()
		-- usercmd.buttons = usercmd.buttons | IN_ATTACK  -- Force attack bit

		msg:ReadFromBitBuffer(moveMsg.buffer)
		charged_ticks = 0 -- consume all ticks
		return true
	end
	return false
end

---@param msg NetMessage
local function MsgManager(msg)
	if msg:GetType() == SIGNONSTATE_TYPE then
		HandleJoinServers(msg)
	end

	if msg:GetType() == CLC_MOVE_TYPE then
		if burst_warping and not recharging then
			HandleBurstWarp(msg)
		elseif warping and not recharging then
			HandleWarp(msg)
		else
			if HandleRecharge(msg) then
				return false
			end
		end
	end
end

---@param usercmd UserCmd
local function HandleInputs(usercmd)
	if engine:IsChatOpen() or engine:Con_IsVisible() or engine:IsGameUIVisible() then
		return
	end
	warping = input.IsButtonDown(settings.warp.key)
	recharging = input.IsButtonDown(settings.recharge.key)
	burst_warping = settings.burst_mode.enabled and input.IsButtonDown(settings.burst_mode.key)
	maxticks = GetMaxServerTicks()

	local localplayer = entities:GetLocalPlayer()
	if not localplayer then
		localplayer_alive = false
		localplayer_velocity = 0
		localplayer_isRed = false
		shooting = false
		return
	end
	localplayer_alive = localplayer:IsAlive()
	localplayer_velocity = localplayer:EstimateAbsVelocity():Length()
	localplayer_isRed = localplayer:GetTeamNumber() == 2

	-- Salvage newly accumulated choked packets (e.g. from genuine network lag) as free recharge
	-- Only when we are NOT currently using warp or manual recharge keys.
	local current_choked = clientstate:GetChokedCommands()
	if not warping and not burst_warping and not recharging and current_choked > last_choked_commands then
		local gained = current_choked - last_choked_commands
		charged_ticks = charged_ticks + gained
	end
	last_choked_commands = current_choked

	-- ------------------------------------------------------------------
	--  Time-based passive recharge fallback (runs every CreateMove tick)
	-- ------------------------------------------------------------------
	if settings.passive_recharge.enabled and not warping and not burst_warping and not recharging then
		-- Instantly max when standing still
		if localplayer_velocity <= 0.1 then
			charged_ticks = maxticks
		else
			if globals.TickCount() >= next_passive_recharge_tick then
				charged_ticks = charged_ticks + 1
				-- Schedule the next passive recharge
				local time = settings.passive_recharge.randomized.enabled
						and engine.RandomInt(
							settings.passive_recharge.randomized.min_time,
							settings.passive_recharge.randomized.max_time
						)
					or settings.passive_recharge.time
				next_passive_recharge_tick = globals.TickCount() + time
			end
		end
	end

	--- i wanted this to be one line lul
	shooting = settings.both.check_aimbot_target
			and (usercmd.buttons & IN_ATTACK ~= 0 or (aimbot.GetAimbotTarget() >= 1 and input.IsButtonDown(
				gui.GetValue("aim key")
			)))
		or (usercmd.buttons & IN_ATTACK ~= 0)

	charged_ticks = clamp(charged_ticks, 0, maxticks)

	local state, tick = input.IsButtonPressed(settings.passive_recharge.toggle_key)
	if state and last_pressed_tick < tick then
		settings.passive_recharge.enabled = not settings.passive_recharge.enabled
		last_pressed_tick = tick
		ChatPrintf("toggled passive recharge")
	end

	if settings.desync.enabled and input.IsButtonDown(settings.desync.key) then
		recharging = true
		usercmd.sendpacket = false
		charged_ticks = 0
	end

	if recharging or warping or burst_warping then
		local player = entities:GetLocalPlayer()
		if not player then
			return
		end
		player:SetPropInt(old_tickbase, "m_nTickBase")
	end
end

local function HandleSpectators()
	if settings.both.ignore_spectators then
		callbacks.Unregister("CreateMove", "SmoothWarpCreateMove2")
		return
	end
	local localplayer = entities:GetLocalPlayer()
	if not localplayer then
		return
	end

	local is_spectated = false

	for _, player in pairs(entities.FindByClass("CTFPlayer")) do
		if not player:IsAlive() then
			local target = player:GetPropEntity("m_hObserverTarget")
			if not target then
				goto continue
			end
			if target == localplayer then
				is_spectated = true
			end
			::continue::
		end
	end

	spectated = is_spectated
end

local function DrawTicks()
	if
		engine:Con_IsVisible()
		or engine:IsGameUIVisible()
		or (engine:IsTakingScreenshot() and gui.GetValue("clean screenshots") == 1)
	then
		return
	end

	local formatted_text <const> = string.format(unformatted_text, charged_ticks, maxticks)
	draw.SetFont(font)
	local textW <const>, textH <const> = draw.GetTextSize(formatted_text)
	local textX <const>, textY <const> = math.floor(centerX - (textW / 2)), math.floor(centerY + textH + 20)

	local cant_warp <const> = gui.GetValue("anti aim") == 1 or gui.GetValue("fake lag") == 1
	local barWidth <const> = 80
	local offset <const> = 2
	local percent <const> = charged_ticks / maxticks
	local barX, barY = centerX - math.floor(barWidth / 2), math.floor(centerY + textH + 20)

	draw.Color(30, 30, 30, 252)
	draw.FilledRect(
		math.floor(barX - offset),
		math.floor(barY - offset),
		math.floor(barX + barWidth + offset),
		math.floor(barY + textH + offset)
	)

	local color = cant_warp and { 0, 0, 0, 255 } or localplayer_isRed and { 236, 57, 57, 255 } or { 12, 116, 191, 255 }
	draw.Color(color[1], color[2], color[3], color[4])
	--- WHERE IS THEFUCKING NUMBER IM GOING CRAZY
	--- so... if you got an error about a number on FilledRect and came to see what it is, dont worry idk where the fk is the problem
	--- just ignore it, as just like all our problems, it'll go away... eventually
	pcall(
		draw.FilledRect,
		math.floor(barX or 0),
		math.floor(barY or 0),
		math.floor((barX or 0) + ((barWidth * (percent or 0)) or 0)),
		math.floor((barY or 0) + (textH or 0))
	)

	draw.SetFont(font)
	draw.Color(255, 255, 255, 255)
	draw.TextShadow(textX, textY, formatted_text)
end

local function TryToFixTickBase(stage)
	if stage == E_ClientFrameStage.FRAME_NET_UPDATE_START then
		local player = entities:GetLocalPlayer()
		if not player then
			return
		end
		old_tickbase = player:GetPropInt("m_nTickBase")
	end
end

callbacks.Unregister("SendNetMsg", "SmoothWarpNetMsg")
callbacks.Register("SendNetMsg", "SmoothWarpNetMsg", MsgManager)

callbacks.Unregister("CreateMove", "SmoothWarpCreateMove")
callbacks.Register("CreateMove", "SmoothWarpCreateMove", HandleInputs)

callbacks.Unregister("Draw", "SmoothWarpDraw")
callbacks.Register("Draw", "SmoothWarpDraw", DrawTicks)

callbacks.Unregister("CreateMove", "SmoothWarpCreateMove2")
callbacks.Register("CreateMove", "SmoothWarpCreateMove2", HandleSpectators)

callbacks.Register("FrameStageNotify", "smoothwarpframestagenotify", TryToFixTickBase)

callbacks.Unregister("Unload", "SmoothWarpUnload")
--- make sure this is unique enough to not register on top of another unload callback
callbacks.Register("Unload", "SmoothWarpUnload", function()
	charged_ticks = nil
	next_passive_recharge_tick = nil
	maxticks = nil
	warping, recharging = nil, nil
	shooting = nil
	localplayer_alive = nil
	localplayer_velocity = nil
end)
