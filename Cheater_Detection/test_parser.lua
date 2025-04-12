-- Test script for the TF2BotDetector parser
local Parsers = require("Cheater_Detection.Database.Parsers")

-- Reset the statistics
Parsers.ResetStats()

-- Sample data (shortened version)
local sampleJson = [[
{
    "$schema": "https://raw.githubusercontent.com/PazerOP/tf2_bot_detector/master/schemas/v3/playerlist.schema.json",
    "file_info": {
        "authors": [
            "pazer"
        ],
        "description": "Official player blacklist for TF2 Bot Detector.",
        "title": "Official player blacklist",
        "update_url": "https://raw.githubusercontent.com/PazerOP/tf2_bot_detector/master/staging/cfg/playerlist.official.json"
    },
    "players": [
        {
            "attributes": [
                "cheater"
            ],
            "last_seen": {
                "player_name": "enzic2",
                "time": 1593821733
            },
            "steamid": "[U:1:1254884]"
        },
        {
            "attributes": [
                "cheater"
            ],
            "last_seen": {
                "player_name": "enzic",
                "time": 1593821733
            },
            "steamid": "[U:1:1602884]"
        },
        {
            "attributes": [
                "racist"
            ],
            "last_seen": {
                "player_name": "Lt.TexasDan[BN]",
                "time": 1624680846
            },
            "steamid": "[U:1:34109857]"
        },
        {
            "attributes": [
                "racist"
            ],
            "last_seen": {
                "player_name": "Rabbi Gabeslave",
                "time": 1615088738
            },
            "steamid": "[U:1:34939669]"
        }
    ]
}
]]

-- Mock database for testing
local testDatabase = {}

-- Source stats for tracking
local sourceStats = {
	processed = 0,
	added = 0,
	existing = 0,
	errors = 0,
}

print("----------------------------------------------------------")
print("Testing ParseTF2BotDetector function...")
print("----------------------------------------------------------")

-- Test with default behavior
local result, error, stats = Parsers.ParseTF2BotDetector(sampleJson, nil, testDatabase, sourceStats)

-- Add to our stats tracker
Parsers.AddSourceStats(
	"Test TF2 Bot Detector",
	sourceStats.processed,
	sourceStats.added,
	sourceStats.existing,
	sourceStats.errors
)

-- Print the results
print("Parse results:")
print(string.format("  Processed: %d entries", sourceStats.processed))
print(string.format("  Added: %d entries", sourceStats.added))
print(string.format("  Errors: %d", sourceStats.errors))
print("\nConverted entries:")

-- Print the converted entries
for steamID64, data in pairs(result) do
	print(string.format("  SteamID64: %s, Name: %s, Reason: %s", steamID64, data.Name, data.Reason))
end

-- Print the statistics summary
print("\nStatistics Summary:")
print(Parsers.GetStatsSummary())

print("----------------------------------------------------------")
print("Test completed")
print("----------------------------------------------------------")
