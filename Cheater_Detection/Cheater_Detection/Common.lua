---@class Common
local Common = {}

---@type boolean, LNXlib
local libLoaded, Lib = pcall(require, "LNXlib")
assert(libLoaded, "LNXlib not found, please install it!")
assert(Lib.GetVersion() >= 0.94, "LNXlib version is too old, please update it!")
Common.Lib = Lib

Common.Log = Lib.Utils.Logger.new("Lmaobot")
Common.FS = Lib.Utils.FileSystem

-- Require Json.lua directly
Common.Json = require("Cheater_Detection.Json")

return Common