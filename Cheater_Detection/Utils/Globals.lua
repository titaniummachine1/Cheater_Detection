--[[ Imports first --]]
local G = {}
G.Menu = require("Cheater_Detection.Utils.DefaultConfig")

G.AutoVote = {
	Options = { "Yes", "No" },
	VoteCommand = "vote",
	VoteIdx = nil,
	VoteValue = nil, -- Set this to 1 for yes, 2 for no, or nil for off
}

--[[Shared Variables]]

G.PlayerData = {}

return G
