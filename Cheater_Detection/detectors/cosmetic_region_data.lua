-- Static defIndex → equip_region map from TF2 items_game.txt (public schema).
-- IMPORTANT: Only include entries you are certain about. A wrong entry causes false
-- positives (flagging legitimate players) which is worse than a miss (no entry).
-- Populate this table from actual items_game.txt data as it becomes available.
-- The equip_region detection in cosmetic_abuse.lua degrades gracefully if this is sparse.
--
-- Region conflict rules (from TF2 wiki):
--   "whole_head" conflicts with: hat, face, glasses, lenses, ears, headphones,
--                                head_misc, hat_lower
--   Two items with the same region conflict with each other.

local M = {
	-- ── whole_head (full-face/full-head items) ─────────────────────────────
	-- These conflict with anything else worn on the head.
	[122]   = "whole_head", -- The HazMat Headcase (Pyro)
	[788]   = "whole_head", -- The Veil (Spy)
	[899]   = "whole_head", -- The Executioner (Heavy)
	[957]   = "whole_head", -- The Janissary Ketche (Soldier)
	[975]   = "whole_head", -- The Stainless Pot (Heavy)
	[1004]  = "whole_head", -- The Blizzard Breather (Heavy)

	-- ── hat (standard headgear that occupies the hat region) ──────────────
	[165]   = "hat", -- The Ghastly Gibus
	[166]   = "hat", -- The Officer's Ushanka (Heavy)
	[168]   = "hat", -- The Bonk Helm (Scout)
	[258]   = "hat", -- The Dead Cone (Engineer)
	[266]   = "hat", -- The Safe'n'Sound (Spy)
	[290]   = "hat", -- The Point and Shoot (Medic)
	[394]   = "hat", -- The Familiar Fez (Medic)
	[31385] = "hat", -- The Mean Captain (all-class) [confirmed via AttrDump in-game]
	[537]   = "hat", -- TF Birthday Hat 2011 (all-class) [confirmed in-game]
	[30177] = "hat", -- Hong Kong Cone (all-class) [confirmed in-game]
	[940]   = "hat", -- Ghostly Gibus (all-class) [confirmed in-game]

	-- ── face (items worn across the face, not full-head) ──────────────────
	[207]   = "face", -- The Whiskered Gentleman (Engineer)
	[384]   = "face", -- The Googly Gazer (all-class)

	-- ── glasses ───────────────────────────────────────────────────────────
	[276]   = "glasses", -- The Sight for Sore Eyes (Sniper)
	[349]   = "glasses", -- The Nerd's Natural Habitat (Engineer)

	-- ── lenses ────────────────────────────────────────────────────────────
	-- (unusual particle effects that sit on the eyes; conflict with glasses)

	-- ── ears ──────────────────────────────────────────────────────────────
	[143]   = "ears", -- The Earbuds (all-class)
}

return M
