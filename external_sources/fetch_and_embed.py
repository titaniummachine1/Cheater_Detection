#!/usr/bin/env python3
"""
External Source Embedder
Fetches frozen/slow TF2 cheater list sources and converts them to
embedded Lua modules for Static_Embeded_Databases/.

Sources embedded (dead or slow - safe to snapshot):
  - d3fc0n6 Cheater List  (last updated Feb 2023, frozen)
  - qfoxb Player List     (last updated Feb 2023, frozen)
  - joekiller List        (last updated Jun 2024, slowing)
  - sleepy main/ext/nullc0re (last updated Jun 2024)
  - TF2BD Official        (PazerOP official bot list)
  - TF2BD Community Biglist (wgetJane, ClusterConsultant meta-repo)
  - TF2BD Community Trusted (TF2BD Discord Trusted role, ClusterConsultant meta-repo)

Sources kept live (actively updated):
  - Masterbase Broadcasts (real-time API)
  - MegaScaterbomb        (actively maintained, also fetched live by Fetcher)
  - qfoxb / joekiller     (live-fetched by Fetcher to catch updates between re-embeds)
"""

import json
import re
import argparse
import urllib.request
from pathlib import Path
from typing import Dict, Optional

# -----------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------
STEAMID64_BASE = 76561197960265728

OUTPUT_DIR = Path(__file__).parent.parent / "Cheater_Detection" / "Database" / "Static_Embeded_Databases"

SOURCES = [
    {
        "name": "d3fc0n6 Cheater List",
        "url": "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/CheaterFriend/64ids",
        "parser": "raw64",
        "source_label": "d3fc0n6 Cheater List",
        "static_id": "d3_cheat",
        "default_reason": "Cheater (d3fc0n6)",
        "output": "d3fc0n6_embedded.lua",
    },
    {
        "name": "qfoxb Player List",
        "url": "https://raw.githubusercontent.com/qfoxb/tf2bd-lists/main/playerlist.qfoxb.json",
        "parser": "tf2bd",
        "source_label": "qfoxb Cheater List",
        "static_id": "qfoxb",
        "default_reason": "Cheater (qfoxb)",
        "output": "qfoxb_embedded.lua",
    },
    {
        "name": "joekiller Player List",
        "url": "https://raw.githubusercontent.com/joekiller/joekiller-list/main/playerlist.joekiller.json",
        "parser": "tf2bd",
        "source_label": "joekiller Cheater List",
        "static_id": "joekiller",
        "default_reason": "Cheater (joekiller)",
        "output": "joekiller_embedded.lua",
    },
    {
        "name": "Sleepy Main List",
        "url": "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.sleepy.json",
        "parser": "tf2bd",
        "source_label": "Sleepy Cheater List",
        "static_id": "sleepy_main",
        "default_reason": "Cheater (Sleepy)",
        "output": "sleepy_main_embedded.lua",
    },
    {
        "name": "Sleepy External List",
        "url": "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.sleepy-external.json",
        "parser": "tf2bd",
        "source_label": "Sleepy External List",
        "static_id": "sleepy_ext",
        "default_reason": "Cheater (Sleepy External)",
        "output": "sleepy_ext_embedded.lua",
    },
    {
        "name": "Sleepy Nullc0re List",
        "url": "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.nullc0re.json",
        "parser": "tf2bd",
        "source_label": "Sleepy Nullc0re List",
        "static_id": "sleepy_nullc0re",
        "default_reason": "Cheater (Sleepy/nullc0re)",
        "output": "sleepy_nullc0re_embedded.lua",
    },
    {
        "name": "TF2BD Official",
        "url": "https://raw.githubusercontent.com/PazerOP/tf2_bot_detector/master/staging/cfg/playerlist.official.json",
        "parser": "tf2bd",
        "source_label": "TF2BD Official",
        "static_id": "tf2bd_off",
        "default_reason": "Bot (TF2BD Official)",
        "output": "tf2bd_official_embedded.lua",
    },
    {
        "name": "TF2BD Community Biglist (wgetJane)",
        "url": "https://raw.githubusercontent.com/ClusterConsultant/TF2BD-Community-Lists/main/playerlist.biglist.json",
        "parser": "tf2bd",
        "source_label": "TF2BD Community Biglist",
        "static_id": "cc_biglist",
        "default_reason": "Bot (TF2BD Community Biglist)",
        "output": "cc_biglist_embedded.lua",
    },
    {
        "name": "TF2BD Community Trusted",
        "url": "https://raw.githubusercontent.com/ClusterConsultant/TF2BD-Community-Lists/main/playerlist.trusted.json",
        "parser": "tf2bd",
        "source_label": "TF2BD Community Trusted",
        "static_id": "cc_trusted",
        "default_reason": "Cheater (TF2BD Trusted)",
        "output": "cc_trusted_embedded.lua",
    },
]

# -----------------------------------------------------------------------
# SteamID helpers
# -----------------------------------------------------------------------
_STEAM3_RE = re.compile(r"\[U:1:(\d+)\]")


def steam3_to_steamid64(steam3: str) -> Optional[str]:
    """Convert [U:1:XXXX] to SteamID64."""
    m = _STEAM3_RE.match(steam3.strip())
    if not m:
        return None
    return str(STEAMID64_BASE + int(m.group(1)))


def steamid64_valid(sid: str) -> bool:
    try:
        v = int(sid)
        return STEAMID64_BASE <= v <= STEAMID64_BASE + 0xFFFFFFFF
    except (ValueError, TypeError):
        return False


# -----------------------------------------------------------------------
# Fetcher
# -----------------------------------------------------------------------
def fetch_url(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


# -----------------------------------------------------------------------
# Parsers
# -----------------------------------------------------------------------
def parse_raw64(raw: bytes, source: dict) -> Dict[str, dict]:
    """Parse newline-separated SteamID64 list."""
    entries = {}
    for line in raw.decode("utf-8").splitlines():
        sid = line.strip()
        if sid and steamid64_valid(sid):
            entries[sid] = {
                "Name": "Unknown",
                "Reason": source["default_reason"],
                "Source": source["source_label"],
                "Static": source["static_id"],
                "Flags": 0,
                "Timestamp": 0,
            }
    return entries


def parse_tf2bd(raw: bytes, source: dict) -> Dict[str, dict]:
    """Parse TF2BD v3 playerlist JSON format."""
    data = json.loads(raw.decode("utf-8"))
    entries = {}

    players = data.get("players", [])
    for player in players:
        steamid_raw = player.get("steamid", "")
        steamid64 = steam3_to_steamid64(steamid_raw)
        if not steamid64:
            # try direct SteamID64
            if steamid64_valid(steamid_raw):
                steamid64 = steamid_raw
            else:
                continue

        attributes = player.get("attributes", [])
        last_seen = player.get("last_seen", {})
        name = last_seen.get("player_name", "Unknown") or "Unknown"
        # Sanitize invisible characters from names
        name = name.encode("ascii", "ignore").decode("ascii").strip() or "Unknown"

        # Build reason from attributes
        attr_str = " | ".join(a.capitalize() for a in attributes) if attributes else ""
        reason = f"{source['default_reason']}"
        if attr_str and attr_str.lower() != "cheater":
            reason = f"{source['default_reason']} ({attr_str})"

        # proof field can enrich reason for sleepy list
        proof = player.get("proof", [])
        if proof:
            proof_clean = [p for p in proof if not p.startswith("[auto]") and not p.startswith("generated")]
            if proof_clean:
                proof_str = proof_clean[0][:80]  # first proof, capped
                reason = f"{reason} - {proof_str}"

        entries[steamid64] = {
            "Name": name,
            "Reason": reason,
            "Source": source["source_label"],
            "Static": source["static_id"],
            "Flags": 0,
            "Timestamp": 0,
        }
    return entries


# -----------------------------------------------------------------------
# Lua output
# -----------------------------------------------------------------------
def escape_lua_string(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "")


def entry_to_lua(steamid64: str, entry: dict) -> str:
    fields = []
    for key, value in entry.items():
        if isinstance(value, str):
            fields.append(f'{key} = "{escape_lua_string(value)}"')
        elif isinstance(value, bool):
            fields.append(f"{key} = {str(value).lower()}")
        elif isinstance(value, int):
            fields.append(f"{key} = {value}")
    return '\t["' + steamid64 + '"] = { ' + ", ".join(fields) + " },"


def generate_lua(entries: Dict[str, dict], source_name: str, source_url: str, use_global_lookup=False, global_lookup_file=None) -> str:
    if use_global_lookup:
        return generate_lua_global_lookup(entries, source_name, source_url, global_lookup_file)
    return generate_lua_verbose(entries, source_name, source_url)


def generate_lua_verbose(entries: Dict[str, dict], source_name: str, source_url: str) -> str:
    """Generate verbose Lua format (legacy)."""
    lines = [
        f"-- Embedded Cheater Database: {source_name}",
        f"-- Source URL: {source_url}",
        f"-- Total Entries: {len(entries)}",
        f"-- Usage: local DB = require('Cheater_Detection.Database.Static_Embeded_Databases.FILENAME')",
        f"-- Access: DB['76561198XXXXXXXXX']",
        "",
        "return {",
    ]
    for sid in sorted(entries.keys()):
        lines.append(entry_to_lua(sid, entries[sid]))
    lines.append("}")
    return "\n".join(lines)


def generate_lua_global_lookup(entries: Dict[str, dict], source_name: str, source_url: str, global_lookup_file=None) -> str:
    """Generate global lookup format (normalized with integer IDs)."""
    # Load global lookup tables if provided to get reverse maps
    source_id_map = {}
    reason_id_map = {}
    static_id_map = {}
    name_id_map = {}
    
    if global_lookup_file and Path(global_lookup_file).exists():
        try:
            with open(global_lookup_file, 'r', encoding='utf-8') as f:
                content = f.read()
            # Parse Sources
            for match in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]+)"', content):
                source_id_map[match.group(2)] = int(match.group(1))
            # Parse Reasons
            for match in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]+)"', content):
                reason_id_map[match.group(2)] = int(match.group(1))
            # Parse Statics
            for match in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]+)"', content):
                static_id_map[match.group(2)] = int(match.group(1))
            # Parse Names
            for match in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]+)"', content):
                name_id_map[match.group(2)] = int(match.group(1))
        except Exception as e:
            print(f"  [WARN] Failed to load global lookup file: {e}")
    
    # No local lookup tables - inline unique strings directly
    lines = [
        f"-- Embedded Cheater Database: {source_name}",
        f"-- Source URL: {source_url}",
        f"-- Total Entries: {len(entries)}",
        f"-- Usage: local DB = require('Cheater_Detection.Database.Static_Embeded_Databases.FILENAME')",
        f"-- Access: DB.Data['76561198XXXXXXXXX']",
        f"-- Format: Global lookup IDs (references global_lookup_tables.lua)",
        "",
        "return {",
        "",
        "\tData = {",
    ]
    
    for sid in sorted(entries.keys()):
        entry = entries[sid]
        source = entry['Source']
        reason = entry['Reason']
        static = entry['Static']
        name = entry['Name']
        flags = entry['Flags']
        
        # Get IDs from global lookup (inline if not found)
        source_id = source_id_map.get(source, source)
        reason_id = reason_id_map.get(reason, reason)
        static_id = static_id_map.get(static, static)
        name_id = name_id_map.get(name, name)
        
        # Format values: integers as-is, strings as quoted
        def format_value(v):
            if isinstance(v, int):
                return str(v)
            else:
                return f'"{escape_lua_string(v)}"'
        
        # Build normalized entry: [Flags, SourceID, ReasonID, StaticID, NameID]
        entry_array = [format_value(flags), format_value(source_id), format_value(reason_id), format_value(static_id), format_value(name_id)]
        
        lines.append(f"\t\t[\"{sid}\"] = {{ {', '.join(entry_array)} }},")
    
    lines.append("\t},")
    lines.append("}")
    
    return "\n".join(lines)


# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
def process_source(source: dict) -> Optional[Dict[str, dict]]:
    print(f"  [FETCH] {source['name']} ...")
    try:
        raw = fetch_url(source["url"])
    except Exception as e:
        print(f"  [ERROR] Failed to fetch: {e}")
        return None

    parser = source["parser"]
    if parser == "raw64":
        entries = parse_raw64(raw, source)
    elif parser == "tf2bd":
        entries = parse_tf2bd(raw, source)
    else:
        print(f"  [ERROR] Unknown parser: {parser}")
        return None

    print(f"  [PARSED] {len(entries)} entries")
    return entries


def main():
    parser = argparse.ArgumentParser(description="External Source Embedder")
    parser.add_argument('--global-lookup', metavar='FILE',
                        help='Use global lookup format (specify path to global_lookup_tables.lua)')
    args = parser.parse_args()
    
    use_global_lookup = args.global_lookup is not None
    
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("External Source Embedder")
    print("=" * 60)
    print(f"Output: {OUTPUT_DIR}")
    if use_global_lookup:
        print(f"Format: Global lookup (using {args.global_lookup})")
    else:
        print(f"Format: Verbose (legacy)")
    print()

    all_entries: Dict[str, dict] = {}

    for source in SOURCES:
        print(f"\n[SOURCE] {source['name']}")
        entries = process_source(source)
        if not entries:
            continue

        # Write individual embedded Lua file
        lua_out = generate_lua(entries, source["name"], source["url"], 
                              use_global_lookup=use_global_lookup, 
                              global_lookup_file=args.global_lookup)
        out_path = OUTPUT_DIR / source["output"]
        out_path.write_text(lua_out, encoding="utf-8")
        print(f"  [SAVED] {out_path}")

        # Merge into combined (prefer existing entries - first seen wins for name)
        for sid, entry in entries.items():
            if sid not in all_entries:
                all_entries[sid] = entry
            else:
                existing = all_entries[sid]
                # Upgrade name if current is Unknown
                if existing["Name"] == "Unknown" and entry["Name"] != "Unknown":
                    existing["Name"] = entry["Name"]
                # Merge reasons if different source
                if entry["Static"] != existing["Static"]:
                    new_reason = entry["Reason"]
                    if new_reason not in existing["Reason"]:
                        existing["Reason"] = existing["Reason"] + " | " + new_reason

    # Write combined
    combined_path = OUTPUT_DIR / "external_combined_embedded.lua"
    combined_lua = generate_lua(all_entries, "External Sources Combined", "various",
                              use_global_lookup=use_global_lookup,
                              global_lookup_file=args.global_lookup)
    combined_lua = combined_lua.replace(
        "-- Source URL: various",
        "-- Sources: d3fc0n6, qfoxb, joekiller, sleepy (main/ext/nullc0re), TF2BD Official, CC Biglist, CC Trusted",
    )
    combined_path.write_text(combined_lua, encoding="utf-8")

    print(f"\n{'=' * 60}")
    print(f"[COMBINED] {combined_path}")
    print(f"[COMBINED] {len(all_entries)} total unique entries")
    print("=" * 60)
    print("\nDone! Files are ready to require() directly in Lua.")
    if use_global_lookup:
        print("Example:")
        print("  local D3DB = require('Cheater_Detection.Database.Static_Embeded_Databases.d3fc0n6_embedded')")
        print("  local entry = D3DB.Data['76561197960376106']")
    else:
        print("Example:")
        print("  local D3DB = require('Cheater_Detection.Database.Static_Embeded_Databases.d3fc0n6_embedded')")
        print("  local entry = D3DB['76561197960376106']")


if __name__ == "__main__":
    main()
