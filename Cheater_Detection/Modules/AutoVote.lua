-- AutoVote Module
local AutoVote = {}

-- Required modules
local Common = require("Cheater_Detection.Common")
local Config = require("Cheater_Detection.Config")
local Globals = require("Cheater_Detection.Globals")
local Lib = Common.Lib
local TF2 = Common.TF2
local Math, Conversion = Common.Math, Common.Conversion
local WPlayer, PR = TF2.WPlayer, TF2.PlayerResource

-- Event hook function for vote options and casting
local function event_hook(ev)
    local eventName = ev:GetName()

    -- Handle vote options event
    if eventName == 'vote_options' then
        for i = 1, ev:GetInt('count') do
            Globals.AutoVote.Options[i] = ev:GetString('option' .. i)
        end
    end

    -- Handle vote cast event
    if eventName == 'vote_cast' then
        local team = ev:GetInt('team')
        local entityid = ev:GetInt('entityid')
        Globals.AutoVote.VoteIdx = ev:GetInt('voteidx')
    end
end

-- Hook for sending string commands
callbacks.Register('SendStringCmd', 'AutoVote_SendStringCmd', function(cmd)
    local input = cmd:Get()
    if input:find(Globals.AutoVote.VoteCommand .. ' option') then
        cmd:Set(input:gsub(Globals.AutoVote.VoteCommand, '%1 ' .. Globals.AutoVote.VoteIdx))
    end
end)

-- Hook for dispatching user messages, particularly for voting
callbacks.Register('DispatchUserMessage', 'AutoVote_DispatchUserMessage', function(msg)
    if msg:GetID() == VoteStart then
        local team = msg:ReadByte()
        local voteidx = msg:ReadInt(32)
        local entidx = msg:ReadByte()
        local disp_str = msg:ReadString(64)
        local details_str = msg:ReadString(64)
        local target_IDX = msg:ReadByte() >> 1

        local ent0, ent1 = entities.GetByIndex(entidx), entities.GetByIndex(target_IDX)
        local me = entities.GetLocalPlayer()
        local voteint = Common.IsCheater(ent0)

        if ent0 ~= me and ent1 ~= me and type(voteint) == 'number' then
            local playerinfo = client.GetPlayerInfo(target_IDX)

            -- Vote no if target is a friend
            local voteint = (TF2.IsFriend(target_IDX, true) and 2) or Common.IsCheater(target_IDX)

            client.ChatPrintf(string.format('\x01Voted %s "%s option%d" (\x05%s\x01)', Globals.AutoVote.Options[voteint], Globals.AutoVote.VoteCommand, voteint, disp_str))
            client.Command(string.format('%s %d option%d', Globals.AutoVote.VoteCommand, voteidx, voteint), true)
        end
    end
end)

-- Registration and unregistration of callbacks
callbacks.Unregister("FireGameEvent", "CD_event_hook") -- Unregister the "FireGameEvent" callback
callbacks.Register("FireGameEvent", "CD_event_hook", event_hook) -- Register the "FireGameEvent" callback

return AutoVote