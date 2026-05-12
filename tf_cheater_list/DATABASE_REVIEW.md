# TF2 Cheater List Database Review

## Overview

The `tf_cheater_list` folder contains community-sourced cheater data in various JSON formats. This document reviews the storage methods and provides a translation solution for integration with the Cheater Detection Lua system.

## Source Files Analysis

### 1. dev.json (15.5 MB)
- **Format**: Object keyed by Steam Account ID (32-bit integer)
- **Entries**: ~17,697 cheaters
- **Fields**:
  - `force_always`: boolean - marks high-priority cheaters
  - `last_submit_time`: Unix timestamp
  - `last_seen_time`: Unix timestamp  
  - `detections`: Object with detection details (server_type, detection_type, time_submitted)
  - `submitters`: Array of usernames who reported
  - `games`: Array of game IDs

### 2. dev_bot_list.json (2.1 MB)
- **Format**: Same as dev.json
- **Entries**: ~3,950 bot accounts
- **Fields**: Same as dev.json (no detections for most)

### 3. alias.json (435 KB)
- **Format**: Array of alias entries
- **Entries**: ~4,197 aliases
- **Fields**:
  - `id`: Steam Account ID
  - `name`: Player name
  - `group`: Category (e.g., "Pedo", "Cheater", "Toxic")
  - `last_seen_time`: Unix timestamp

### 4. bot_name_list.json (3.9 KB)
- **Format**: Simple array of Account IDs
- **Entries**: ~265 bot IDs
- **Fields**: Just the Account ID number

### 5. not_a_bot.json (198 bytes)
- **Format**: Small array of Account IDs
- **Entries**: ~13 IDs marked as "not bots"

## Translation Solution

### Python Script: `translate_to_lua_db.py`

Created a translation script that:

1. **Converts Account IDs to SteamID64**
   - Formula: `SteamID64 = 76561197960265728 + AccountID`
   - Handles 32-bit unsigned account IDs properly

2. **Parses each source format**
   - `dev.json`/`dev_bot_list.json`: Object-based with detections
   - `alias.json`: Array-based with group metadata
   - `bot_name_list.json`: Simple array format

3. **Generates Lua-compatible output**
   - Two formats generated:
     - `.txt` files: Native Lua table format (for direct loading)
     - `.json` files: JSON format (for Lua JSON parser)

4. **Field Mapping**
   | Source Field | Lua Database Field | Notes |
   |-------------|-------------------|-------|
   | (calculated) | `SteamID64` | Key for the entry |
   | alias.name | `Name` | "Unknown" if not available |
   | detections | `Reason` | Detection types appended |
   | (source file) | `Source` | Source identifier |
   | (source file) | `Static` | Static source marker |
   | force_always | `Flags` | 1 if force_always=true |
   | (stripped) | `Timestamp` | Set to 0 |

5. **Merging Strategy**
   - Duplicate SteamIDs across files are merged
   - Names from alias.json take precedence
   - Reasons are concatenated with "|" separator
   - Groups from alias.json preserved in reason

### Source Identifiers Assigned

| File | Source ID | Static ID |
|------|-----------|-----------|
| dev.json | tfcl_dev | tfcl_dev |
| dev_bot_list.json | tfcl_bot | tfcl_bot |
| alias.json | tfcl_alias | tfcl_alias |
| bot_name_list.json | tfcl_botnames | tfcl_botnames |
| not_a_bot.json | tfcl_notabot | tfcl_notabot |

## Output Files

Generated in `translated_output/`:

| File | Format | Entries |
|------|--------|---------|
| `dev_lua.txt` | Lua table | 17,697 |
| `dev_bot_list_lua.txt` | Lua table | 3,950 |
| `alias_lua.txt` | Lua table | 4,197 |
| `bot_name_list_lua.txt` | Lua table | 265 |
| `not_a_bot_lua.txt` | Lua table | 13 |
| `tfcl_combined_lua.txt` | Lua table | **22,446** (unique) |

Same files also available as `.json` for JSON parser compatibility.

## Integration Options

### Option 1: Manual Import (Recommended)
Copy the combined file to your database location:
```
tfcl_combined_lua.txt -> Lua Cheater_Detection/database.txt
```

The Lua database loader in `Database.lua` supports multiple formats:
- Native Lua table format (`.txt` files generated)
- JSON format (fallback)

### Option 2: Auto-Import via Fetcher
Place files in the imports folder:
```
translated_output/*.json -> Lua Cheater_Detection/imports/
```

The Fetcher in `Fetcher.lua` auto-scans this folder on startup.

### Option 3: Add as New Sources
Add entries to `Sources.lua` pointing to the translated files:
```lua
{
    name = "TF2 Cheater List",
    url = "local:tfcl_combined_lua.json",
    cause = "TF2CL Database",
    parser = "tf2db",
    sourceID = "tfcl_combined"
}
```

## Notes

1. **No Names in dev.json**: The original format doesn't store player names. Names come from alias.json only.
2. **Detection Types Preserved**: Detection reasons like "OBB PITCH", "TICKBASE ABUSE", "INVALID EQUIP REGION" are kept in the Reason field.
3. **Timestamps Stripped**: `last_seen_time` and `last_submit_time` were deemed unnecessary per user request.
4. **Force Flag**: Entries with `force_always=true` get Flags=1 for priority marking.
5. **Unique Entries**: 22,446 unique SteamIDs after merging all sources (there's ~3,000+ overlap between files).

## Future Improvements

1. **HTTP-less ID Resolution**: Could implement Steam Web API calls to fetch current names, but would require API key and be slower.
2. **Live Updates**: Script can be re-run when tf_cheater_list files update.
3. **Detection Count**: Script tracks detection count internally (could expose as metadata if needed).
