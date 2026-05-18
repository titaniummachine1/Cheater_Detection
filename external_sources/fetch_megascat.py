#!/usr/bin/env python3
"""Fetch and convert MegaScaterbomb database to embedded Lua format."""
import json
import urllib.request
from pathlib import Path

URL = "https://raw.githubusercontent.com/ill5-com/megascatterbomb-tf2-cheater-database/main/megascatterbomb-tf2-cheater-database.min.json"
OUTPUT = Path(__file__).parent.parent / "Cheater_Detection" / "Database" / "Static_Embeded_Databases" / "megascat_embedded.lua"

def escape_lua(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "")

def main():
    print(f"[FETCH] MegaScaterbomb database...")
    req = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode("utf-8"))

    entries = []
    for player in data:
        sid = player.get("id", "")
        if not sid or not sid.startswith("7656119"):
            continue
        
        name = player.get("label", "Unknown") or "Unknown"
        name = name.encode("ascii", "ignore").decode("ascii").strip() or "Unknown"
        
        # Replace SteamID64 names with "Unknown"
        if name.startswith("7656119") and len(name) == 17 and name.isdigit():
            name = "Unknown"
        
        ptype = player.get("type", "cheater")
        reason = f"MegaScaterbomb ({ptype})"
        
        # Add first alias to reason if available
        aliases = player.get("aliases", [])
        if aliases and len(aliases) > 0:
            alias_clean = str(aliases[0]).encode("ascii", "ignore").decode("ascii")[:40]
            if alias_clean:
                reason = f"{reason} - {alias_clean}"
        
        entry = f'\t["{sid}"] = {{ Name = "{escape_lua(name)}", Reason = "{escape_lua(reason)}", Source = "MegaScaterbomb", Static = "mega_scat", Flags = 0 }},'
        entries.append(entry)

    lua_content = f"""-- Embedded Cheater Database: MegaScaterbomb
-- Source URL: {URL}
-- Total Entries: {len(entries)}
-- Usage: local DB = require('Cheater_Detection.Database.Static_Embeded_Databases.megascat_embedded')

return {{
{chr(10).join(entries)}
}}
"""
    
    OUTPUT.write_text(lua_content, encoding="utf-8")
    print(f"[SAVED] {OUTPUT} with {len(entries)} entries")

if __name__ == "__main__":
    main()
