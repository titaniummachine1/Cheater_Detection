#!/usr/bin/env python3
"""
TF2 Cheater List Translator
Converts tf_cheater_list JSON files to Lua database format

Sources:
- dev.json: Main cheater database (Account ID -> SteamID64)
- dev_bot_list.json: Bot list (Account ID -> SteamID64)
- alias.json: Aliases with groups (Account ID -> SteamID64)
- bot_name_list.json: Simple bot ID list (Account ID -> SteamID64)

Output format matches Cheater_Detection Database.lua:
{
  [SteamID64] = {
    Name = "player_name",
    Reason = "cheater_reason",
    Source = "source_identifier",
    Static = "source_id_or_true",
    Flags = number,
    Timestamp = unix_timestamp
  }
}
"""

import json
import os
from pathlib import Path
from typing import Dict, Any, Optional

# SteamID conversion constant
STEAMID64_BASE = 76561197960265728

# Source mapping for tf_cheater_list files
SOURCE_MAP = {
    "dev.json": {
        "source_id": "Rijin Cheater List",
        "static_id": "tfcl_dev",
        "default_reason": "Cheater (Rijin)"
    },
    "dev_bot_list.json": {
        "source_id": "Rijin Cheater List",
        "static_id": "tfcl_bot",
        "default_reason": "Bot (Rijin)"
    },
    "alias.json": {
        "source_id": "Rijin Cheater List",
        "static_id": "tfcl_alias",
        "default_reason": "Cheater (Rijin Alias)"
    },
    "bot_name_list.json": {
        "source_id": "Rijin Cheater List",
        "static_id": "tfcl_botnames",
        "default_reason": "Bot (Rijin)"
    },
    "not_a_bot.json": {
        "source_id": "Rijin Cheater List",
        "static_id": "tfcl_notabot",
        "default_reason": "Not a Bot (Rijin)"
    }
}


def account_id_to_steamid64(account_id: int | str) -> Optional[str]:
    """Convert Steam Account ID to SteamID64."""
    try:
        acc_id = int(account_id)
        if acc_id < 0 or acc_id > 0xFFFFFFFF:
            return None
        steamid64 = STEAMID64_BASE + acc_id
        return str(steamid64)
    except (ValueError, TypeError):
        return None


def build_reason_from_detections(detections: Dict[str, Any]) -> str:
    """Build a reason string from detection_type fields."""
    if not detections or not isinstance(detections, dict):
        return ""

    detection_types = set()
    for detection_data in detections.values():
        if isinstance(detection_data, dict):
            det_type = detection_data.get("detection_type", "").strip()
            if det_type:
                detection_types.add(det_type.strip("()"))

    return " | ".join(sorted(detection_types)) if detection_types else ""


def parse_dev_json(data: Dict[str, Any], source_config: Dict[str, str]) -> Dict[str, Dict]:
    """Parse dev.json format (Account ID keyed dict with detections)."""
    entries = {}
    
    for account_id, player_data in data.items():
        steamid64 = account_id_to_steamid64(account_id)
        if not steamid64:
            continue
        
        # Skip if no real data (empty detections, no submitters)
        force_always = player_data.get("force_always", False)
        detections = player_data.get("detections", {})
        submitters = player_data.get("submitters", [])
        
        # Build reason from detections; fall back to default only if no detections
        detection_reason = build_reason_from_detections(detections)
        reason = detection_reason if detection_reason else source_config['default_reason']
        
        # Determine flags based on force_always
        flags = 0
        if force_always:
            # Mark as cheater with force flag
            flags = 1  # CHEATER flag (assumed value)
        
        entry = {
            "Name": "Unknown",  # No name in this format
            "Reason": reason,
            "Source": source_config['source_id'],
            "Static": source_config['static_id'],
            "Flags": flags,
            "Timestamp": 0,
            "_detections": len(detections) if detections else 0,
            "_submitters": len(submitters) if submitters else 0,
            "_force_always": force_always
        }
        
        entries[steamid64] = entry
    
    return entries


def parse_alias_json(data: list, source_config: Dict[str, str]) -> Dict[str, Dict]:
    """Parse alias.json format (array of alias entries)."""
    entries = {}
    
    for alias_entry in data:
        if not isinstance(alias_entry, dict):
            continue
        
        account_id = alias_entry.get("id")
        name = alias_entry.get("name", "Unknown")
        group = alias_entry.get("group", "")
        
        steamid64 = account_id_to_steamid64(account_id)
        if not steamid64:
            continue
        
        # Build reason with group if available
        if group:
            reason = f"{source_config['default_reason']} - {group}"
        else:
            reason = source_config['default_reason']
        
        entry = {
            "Name": name,
            "Reason": reason,
            "Source": source_config['source_id'],
            "Static": source_config['static_id'],
            "Flags": 0,
            "Timestamp": 0,
            "_group": group
        }
        
        entries[steamid64] = entry
    
    return entries


def parse_bot_name_list(data: list, source_config: Dict[str, str]) -> Dict[str, Dict]:
    """Parse bot_name_list.json format (simple array of Account IDs)."""
    entries = {}
    
    for account_id in data:
        steamid64 = account_id_to_steamid64(account_id)
        if not steamid64:
            continue
        
        entry = {
            "Name": "Unknown",
            "Reason": source_config['default_reason'],
            "Source": source_config['source_id'],
            "Static": source_config['static_id'],
            "Flags": 0,
            "Timestamp": 0
        }
        
        entries[steamid64] = entry
    
    return entries


def merge_entries(existing: Dict[str, Dict], new_entries: Dict[str, Dict]) -> Dict[str, Dict]:
    """Merge new entries into existing, preferring entries with more info."""
    for steamid64, new_entry in new_entries.items():
        if steamid64 in existing:
            # Merge: keep better name if we have one
            existing_entry = existing[steamid64]
            
            # Update name if new one is better
            if new_entry.get("Name") != "Unknown":
                if existing_entry.get("Name") == "Unknown":
                    existing_entry["Name"] = new_entry["Name"]
            
            # Merge reasons if different
            if new_entry.get("Reason") != existing_entry.get("Reason"):
                existing_reason = existing_entry.get("Reason", "")
                new_reason = new_entry.get("Reason", "")
                if new_reason and new_reason not in existing_reason:
                    existing_entry["Reason"] = f"{existing_reason} | {new_reason}"
            
            # Keep track of all groups
            if "_group" in new_entry:
                if "_groups" not in existing_entry:
                    existing_entry["_groups"] = []
                existing_entry["_groups"].append(new_entry["_group"])
        else:
            existing[steamid64] = new_entry
    
    return existing


def clean_entry_for_output(entry: Dict) -> Dict:
    """Remove internal tracking fields from entry and sanitize values."""
    cleaned = {}
    for key, value in entry.items():
        if not key.startswith("_"):
            # Fix empty name
            if key == "Name" and (not value or value == ""):
                cleaned[key] = "Unknown"
            else:
                cleaned[key] = value
    return cleaned


def _entry_to_lua_fields(cleaned: Dict) -> str:
    """Serialize a cleaned entry dict to Lua inline fields."""
    fields = []
    for key, value in cleaned.items():
        if isinstance(value, str):
            escaped = value.replace('"', '\\"')
            fields.append(f'{key} = "{escaped}"')
        elif isinstance(value, bool):
            fields.append(f'{key} = {str(value).lower()}')
        elif isinstance(value, int):
            fields.append(f'{key} = {value}')
    return ", ".join(fields)


def generate_lua_table(entries: Dict[str, Dict], module_name: str = "TFCLData") -> str:
    """Generate a named Lua module (local X = {} ... return X) for per-source files."""
    lines = [
        f"-- TF2 Cheater List Database Module: {module_name}",
        f"-- Total Entries: {len(entries)}",
        "",
        f"local {module_name} = {{}}",
        "",
        f"{module_name}.List = {{",
    ]
    for steamid64 in sorted(entries.keys()):
        cleaned = clean_entry_for_output(entries[steamid64])
        lines.append('\t["' + steamid64 + '"] = { ' + _entry_to_lua_fields(cleaned) + ' },')
    lines.extend([
        "}",
        "",
        f"function {module_name}.Get(steamID64)",
        f"\treturn {module_name}.List[steamID64]",
        f"end",
        "",
        f"function {module_name}.Contains(steamID64)",
        f"\treturn {module_name}.List[steamID64] ~= nil",
        f"end",
        "",
        f"return {module_name}",
    ])
    return "\n".join(lines)


def generate_combined_lua(entries: Dict[str, Dict]) -> str:
    """Generate a simple 'return { ... }' table - require() returns the table directly."""
    lines = [
        "-- Rijin Cheater List - Combined Database",
        f"-- Total Entries: {len(entries)}",
        "-- Usage: local RijinDB = require('path.to.tfcl_combined_lua')",
        "-- Access: RijinDB['76561198XXXXXXXXX']",
        "",
        "return {",
    ]
    for steamid64 in sorted(entries.keys()):
        cleaned = clean_entry_for_output(entries[steamid64])
        lines.append('\t["' + steamid64 + '"] = { ' + _entry_to_lua_fields(cleaned) + ' },')
    lines.append("}")
    return "\n".join(lines)


def generate_json_output(entries: Dict[str, Dict]) -> str:
    """Generate JSON string from entries (for Lua JSON parser compatibility)."""
    output_entries = {}
    for steamid64, entry in entries.items():
        output_entries[steamid64] = clean_entry_for_output(entry)
    
    return json.dumps(output_entries, indent=2, ensure_ascii=False)


def translate_all(input_dir: Path, output_dir: Path):
    """Process all tf_cheater_list JSON files."""
    output_dir.mkdir(parents=True, exist_ok=True)
    
    all_entries = {}
    stats = {}
    
    json_files = [
        "dev.json",
        "dev_bot_list.json", 
        "alias.json",
        "bot_name_list.json",
        "not_a_bot.json"
    ]
    
    for filename in json_files:
        filepath = input_dir / filename
        if not filepath.exists():
            print(f"[SKIP] {filename} not found")
            continue
        
        print(f"[PROCESSING] {filename}...")
        
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                data = json.load(f)
        except json.JSONDecodeError as e:
            print(f"[ERROR] Failed to parse {filename}: {e}")
            continue
        except Exception as e:
            print(f"[ERROR] Failed to read {filename}: {e}")
            continue
        
        source_config = SOURCE_MAP.get(filename, {
            "source_id": "tfcl_unknown",
            "name": f"TFCL {filename}",
            "default_reason": f"TFCL ({filename})",
            "static": f"tfcl_{filename.replace('.', '_')}"
        })
        
        # Parse based on format
        if filename in ("dev.json", "dev_bot_list.json"):
            entries = parse_dev_json(data, source_config)
        elif filename == "alias.json":
            entries = parse_alias_json(data, source_config)
        elif filename in ("bot_name_list.json", "not_a_bot.json"):
            if isinstance(data, list):
                entries = parse_bot_name_list(data, source_config)
            elif isinstance(data, dict):
                entries = parse_dev_json(data, source_config)
            else:
                entries = {}
        else:
            entries = {}
        
        # Save individual file output
        stats[filename] = len(entries)
        
        # Generate Lua format output
        lua_output = generate_lua_table(entries)
        lua_filepath = output_dir / f"{filename.replace('.json', '_lua.lua')}"
        with open(lua_filepath, 'w', encoding='utf-8') as f:
            f.write(lua_output)
        print(f"  [SAVED] {lua_filepath} ({len(entries)} entries)")
        
        # Generate JSON format output
        json_output = generate_json_output(entries)
        json_filepath = output_dir / f"{filename.replace('.json', '_lua.json')}"
        with open(json_filepath, 'w', encoding='utf-8') as f:
            f.write(json_output)
        print(f"  [SAVED] {json_filepath}")
        
        # Merge into combined database
        all_entries = merge_entries(all_entries, entries)
    
    # Save combined database (simple return {} so require() returns the table)
    combined_lua = output_dir / "tfcl_combined_lua.lua"
    with open(combined_lua, 'w', encoding='utf-8') as f:
        f.write(generate_combined_lua(all_entries))
    print(f"\n[COMBINED] {combined_lua} ({len(all_entries)} total unique entries)")
    
    combined_json = output_dir / "tfcl_combined_lua.json"
    with open(combined_json, 'w', encoding='utf-8') as f:
        f.write(generate_json_output(all_entries))
    print(f"[COMBINED] {combined_json}")
    
    # Print stats
    print("\n" + "="*50)
    print("TRANSLATION STATS:")
    print("="*50)
    for filename, count in stats.items():
        print(f"  {filename}: {count} entries")
    print(f"  UNIQUE TOTAL: {len(all_entries)} entries")
    print("="*50)
    
    return all_entries


def main():
    # Get script directory
    script_dir = Path(__file__).parent
    input_dir = script_dir
    output_dir = script_dir / "translated_output"
    
    print("="*50)
    print("TF2 Cheater List Translator")
    print("="*50)
    print(f"Input:  {input_dir}")
    print(f"Output: {output_dir}")
    print("="*50 + "\n")
    
    entries = translate_all(input_dir, output_dir)
    
    print("\nTranslation complete!")
    print(f"Output files are in: {output_dir}")


if __name__ == "__main__":
    main()
