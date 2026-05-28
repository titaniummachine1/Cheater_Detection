#!/usr/bin/env python3
"""
rebuild_embedded_databases.py

Re-fetches all embeddable sources and regenerates every embedded Lua database
file with weight-based reason normalization:

  - When the same player appears in multiple sources, the highest-weight reason
    is kept.  Lower-weight sources (bot lists, generic griefing) can never
    override higher-weight detections (aimbot, VAC ban, trusted cheater marks).
  - Each individual per-source file contains only that source's data.
  - external_combined_embedded.lua contains the best-reason-per-player across
    all sources.
  - global_lookup_tables.lua is regenerated from scratch after all files are
    produced, so integer IDs stay consistent across every file.

Usage:
    python rebuild_embedded_databases.py
    python rebuild_embedded_databases.py --dry-run   # print stats, no file writes
"""

import json
import re
import sys
import argparse
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR  = Path(__file__).parent
REPO_ROOT   = SCRIPT_DIR.parent
OUTPUT_DIR  = REPO_ROOT / "Cheater_Detection" / "Database" / "Static_Embeded_Databases"
TFCL_FILE   = OUTPUT_DIR / "tfcl_combined_lua.lua"

# ---------------------------------------------------------------------------
# Weight tables (mirrors constants.lua exactly)
# ---------------------------------------------------------------------------

# Source weight: keyed by the static_id used in each source definition below.
SOURCE_WEIGHTS: Dict[str, int] = {
    "local_detector":       100,
    "manual_flag":          95,
    "valve_official":       90,
    "vac_ban":              85,
    "cc_trusted":           80,
    "masterbase_broadcasts": 79,
    "tf2bd_off":            75,
    "sleepy_main":          65,
    "sleepy_nullc0re":      65,
    "d3_cheat":             60,
    "qfoxb":                55,
    "joekiller":            55,
    "mega_scat":            78,
    "sleepy_ext":           40,
    "external_combined":    35,
    "tfcl_dev":             30,
    "tfcl_alias":           30,
    "tfcl_bot":             30,
    "tfcl_botnames":        30,
    "tfcl_combined":        30,
    "cc_biglist":           29,
    "unknown":              0,
}

# Reason category weights: list of (substring, weight) pairs checked in order.
# First match wins.  Plain-string containment (case-sensitive), mirroring Lua.
REASON_WEIGHTS: List[Tuple[str, int]] = [
    # Hard-cheat analytical signals (physically impossible)
    ("ANGLE ANALYTICAL",        100),
    ("OBB PITCH",               100),
    ("OB PITCH",                100),
    ("SPEEDHACK",               100),
    ("TICKBASE ABUSE",          100),
    # Anti-aim
    ("ANTI.AIM",                98),
    ("anti.aim",                98),
    ("ANTI_AIM",                98),
    ("AntiAim",                 98),
    ("anti_aim",                98),
    ("Anti-Aim",                98),
    ("anti-aim",                98),
    # Aimbot
    ("Aimbot",                  98),
    ("aimbot",                  98),
    ("Silent",                  97),
    ("silent",                  97),
    # Exploits
    ("Warp",                    96),
    ("warp",                    96),
    ("Doubletap",               96),
    ("doubletap",               96),
    ("Fake Lag",                90),
    ("fake_lag",                90),
    ("Choke",                   90),
    ("Duck Speed",              85),
    ("duck_speed",              85),
    ("Bhop",                    80),
    ("bhop",                    80),
    # Missing hard cheats (fill gaps)
    ("Spinbot",                  98),
    ("spinbot",                  98),
    ("Backtrack",                98),
    ("backtrack",                98),
    ("Triggerbot",               97),
    ("triggerbot",               97),
    ("Trigger",                  97),
    ("trigger",                  97),
    ("Wallhack",                 95),
    ("wallhack",                 95),
    ("ESP",                      95),
    ("esp",                      95),
    ("Crithack",                 90),
    ("crithack",                 90),
    ("Autostrafe",               85),
    ("autostrafe",               85),
    ("Auto strafe",              85),
    ("auto strafe",              85),
    ("Resolver",                 90),
    ("resolver",                 90),
    ("Edge Jump",                80),
    ("edge jump",                80),
    ("Edge-Jump",                80),
    ("edge-jump",                80),
    ("Edgejump",                 80),
    ("edgejump",                 80),
    ("Noisemaker",               75),
    ("noisemaker",               75),
    ("Noise maker",              75),
    ("noise maker",              75),
    # Valve / VAC confirmed
    ("VALVe",                   95),
    ("Valve employee",          95),
    ("valve employee",          95),
    ("VAC",                     90),
    ("Game Ban",                88),
    # Trusted source cheater marks
    ("Cheater (TF2BD Trusted)", 85),
    ("Cheater (Rijin)",         75),
    ("Cheater (Sleepy",         65),
    ("Cheater (qfoxb)",         60),
    ("Cheater (joekiller)",     60),
    ("Cheater (d3fc0n6)",       60),
    ("Cheater",                 50),
    # Exploiter
    ("Exploiter",               55),
    ("exploiter",               55),
    # Suspicious
    ("Suspicious",              30),
    ("suspicious",              30),
    # Bot marks (high priority - distinguish bots from real players)
    ("Not a Bot",                0),
    ("not a bot",                0),
    ("Bot (",                   85),
    ("BOT SUBMITTED",           85),
    # Generic / low-quality marks
    ("TOO MANY INFRACTIONS",    10),
    ("Racist",                  5),
    ("racist",                  5),
    ("Grief",                   5),
    ("grief",                   5),
    ("suboptimal",              2),
    ("Suboptimal",              2),
]


def score_reason(reason: Optional[str]) -> int:
    """Return the weight of a reason string (0 if unknown/None)."""
    if not reason:
        return 0
    for substring, weight in REASON_WEIGHTS:
        if substring in reason:
            return weight
    return 0


def score_source(static_id: Optional[str]) -> int:
    """Return the weight of a source static_id (0 if unknown/None)."""
    if not static_id:
        return 0
    return SOURCE_WEIGHTS.get(static_id, 0)


def should_override(existing: dict, incoming: dict) -> bool:
    """
    Return True if `incoming` should replace `existing`.
    Uses reason weight as primary comparator; source weight breaks ties.
    """
    ew = score_reason(existing.get("Reason"))
    iw = score_reason(incoming.get("Reason"))
    if iw != ew:
        return iw > ew
    # Equal reason weight → prefer higher-weight source
    es = score_source(existing.get("Static"))
    iws = score_source(incoming.get("Static"))
    return iws > es


# ---------------------------------------------------------------------------
# SteamID helpers
# ---------------------------------------------------------------------------
STEAMID64_BASE = 76561197960265728
_STEAM3_RE = re.compile(r"\[U:1:(\d+)\]")


def steam3_to_sid64(raw: str) -> Optional[str]:
    m = _STEAM3_RE.match(raw.strip())
    if not m:
        return None
    return str(STEAMID64_BASE + int(m.group(1)))


def sid64_valid(sid: str) -> bool:
    try:
        v = int(sid)
        return STEAMID64_BASE <= v <= STEAMID64_BASE + 0xFFFFFFFF
    except (ValueError, TypeError):
        return False


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
def fetch_url(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=45) as resp:
        return resp.read()


# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------

def _sanitize_name(raw: str) -> str:
    """Strip non-ASCII and SteamID64 placeholders."""
    cleaned = raw.encode("ascii", "ignore").decode("ascii").strip()
    if cleaned.startswith("7656119") and len(cleaned) == 17 and cleaned.isdigit():
        return "Unknown"
    return cleaned or "Unknown"


def parse_raw64(raw: bytes, source: dict) -> Dict[str, dict]:
    entries: Dict[str, dict] = {}
    for line in raw.decode("utf-8").splitlines():
        sid = line.strip()
        if sid and sid64_valid(sid):
            entries[sid] = {
                "Name":   "Unknown",
                "Reason": source["default_reason"],
                "Source": source["source_label"],
                "Static": source["static_id"],
                "Flags":  0,
            }
    return entries


def parse_tf2bd(raw: bytes, source: dict) -> Dict[str, dict]:
    data = json.loads(raw.decode("utf-8"))
    entries: Dict[str, dict] = {}

    for player in data.get("players", []):
        sid_raw = player.get("steamid", "")
        sid64   = steam3_to_sid64(sid_raw) or (sid_raw if sid64_valid(sid_raw) else None)
        if not sid64:
            continue

        name  = _sanitize_name(player.get("last_seen", {}).get("player_name", "") or "")
        attrs = player.get("attributes", [])

        attr_str = " | ".join(a.capitalize() for a in attrs) if attrs else ""
        reason   = source["default_reason"]
        if attr_str and attr_str.lower() not in {"cheater", ""}:
            reason = f"{reason} ({attr_str})"

        proof = player.get("proof", [])
        if proof:
            clean_proof = [p for p in proof
                           if not p.startswith("[auto]") and not p.startswith("generated")]
            if clean_proof:
                reason = f"{reason} - {clean_proof[0][:80]}"

        entries[sid64] = {
            "Name":   name,
            "Reason": reason,
            "Source": source["source_label"],
            "Static": source["static_id"],
            "Flags":  0,
        }
    return entries


def parse_megascat(raw: bytes, source: dict) -> Dict[str, dict]:
    data   = json.loads(raw.decode("utf-8"))
    entries: Dict[str, dict] = {}

    for player in data:
        sid = player.get("id", "")
        if not sid or not sid64_valid(sid):
            continue

        name    = _sanitize_name(player.get("label", "") or "")
        ptype   = player.get("type", "cheater")
        reason  = f"MegaScaterbomb ({ptype})"

        aliases = player.get("aliases", [])
        if aliases:
            alias = str(aliases[0]).encode("ascii", "ignore").decode("ascii")[:40].strip()
            if alias:
                reason = f"{reason} - {alias}"

        entries[sid] = {
            "Name":   name,
            "Reason": reason,
            "Source": source["source_label"],
            "Static": source["static_id"],
            "Flags":  0,
        }
    return entries


# ---------------------------------------------------------------------------
# Lua output helpers
# ---------------------------------------------------------------------------

def esc(s: str) -> str:
    return (s.replace("\\", "\\\\")
             .replace('"',  '\\"')
             .replace("\n", "\\n")
             .replace("\r", ""))


def _fmt(v) -> str:
    if isinstance(v, int):
        return str(v)
    return f'"{esc(str(v))}"'


def build_global_lookup(
    all_verbose: Dict[str, Dict[str, dict]]  # { file_key: { steamid: entry } }
) -> Tuple[dict, dict, dict, dict]:
    """
    Build Sources/Reasons/Statics/Names lookup tables from all verbose entries.
    Returns (sources_map, reasons_map, statics_map, names_map)
    where each map is  string -> integer_id  (1-based, sorted alphabetically).
    """
    src_ctr: Counter = Counter()
    rsn_ctr: Counter = Counter()
    stc_ctr: Counter = Counter()
    nme_ctr: Counter = Counter()

    for entries in all_verbose.values():
        for e in entries.values():
            src_ctr[e["Source"]] += 1
            rsn_ctr[e["Reason"]] += 1
            stc_ctr[e["Static"]] += 1
            nme_ctr[e["Name"]]   += 1

    def make_map(ctr: Counter, min_count: int = 1) -> dict:
        return {v: i + 1 for i, v in enumerate(sorted(ctr.keys())) if ctr[v] >= min_count}

    # Names only compressed when they appear 4+ times (saves space for rare names)
    return (
        make_map(src_ctr, 1),
        make_map(rsn_ctr, 1),
        make_map(stc_ctr, 1),
        make_map(nme_ctr, 4),
    )


def encode_entry(entry: dict, src_m: dict, rsn_m: dict, stc_m: dict, nme_m: dict) -> str:
    """Encode a verbose entry into the compressed array string."""
    flags  = entry.get("Flags", 0)
    src    = src_m.get(entry["Source"],  entry["Source"])
    rsn    = rsn_m.get(entry["Reason"],  entry["Reason"])
    stc    = stc_m.get(entry["Static"],  entry["Static"])
    nme    = nme_m.get(entry["Name"],    entry["Name"])
    return f"{{ {_fmt(flags)}, {_fmt(src)}, {_fmt(rsn)}, {_fmt(stc)}, {_fmt(nme)} }}"


def write_individual_file(
    path: Path,
    source_name: str,
    source_url: str,
    entries: Dict[str, dict],
    src_m: dict, rsn_m: dict, stc_m: dict, nme_m: dict,
) -> None:
    lines = [
        f"-- Embedded Database: {source_name}",
        f"-- Source URL: {source_url}",
        f"-- Format: Global lookup IDs (references global_lookup_tables.lua)",
        f"-- Total Entries: {len(entries)}",
        "",
        "return {",
        "    Data = {",
    ]
    for sid in sorted(entries.keys()):
        enc = encode_entry(entries[sid], src_m, rsn_m, stc_m, nme_m)
        lines.append(f'        ["{sid}"] = {enc},')
    lines += ["    },", "}"]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_global_lookup(
    path: Path,
    src_m: dict, rsn_m: dict, stc_m: dict, nme_m: dict,
    db_count: int,
) -> None:
    """Write global_lookup_tables.lua including the reverse-map bootstrapping code."""

    def table_block(name: str, mapping: dict) -> List[str]:
        rev  = {v: k for k, v in mapping.items()}
        rows = [f"        [{i}] = \"{esc(rev[i])}\"," for i in sorted(rev.keys())]
        return [f"    {name} = {{"] + rows + ["    },"]

    lines = [
        "-- Global Lookup Tables for Embedded Databases",
        "-- Contains Sources, Reasons, Statics, and Names shared across all embedded files",
        "-- All embedded databases reference these IDs instead of duplicating strings",
        f"-- Generated from {db_count} embedded database files",
        "",
        "local GlobalTables = {",
    ]
    lines += table_block("Sources", src_m)
    lines += table_block("Reasons", rsn_m)
    lines += table_block("Statics", stc_m)
    lines += table_block("Names",   nme_m)
    lines += [
        "}",
        "",
        "GlobalTables.Sources_rev = {}",
        "for k, v in pairs(GlobalTables.Sources) do GlobalTables.Sources_rev[v] = k end",
        "",
        "GlobalTables.Reasons_rev = {}",
        "for k, v in pairs(GlobalTables.Reasons) do GlobalTables.Reasons_rev[v] = k end",
        "",
        "GlobalTables.Statics_rev = {}",
        "for k, v in pairs(GlobalTables.Statics) do GlobalTables.Statics_rev[v] = k end",
        "",
        "GlobalTables.Names_rev = {}",
        "for k, v in pairs(GlobalTables.Names) do GlobalTables.Names_rev[v] = k end",
        "",
        "return GlobalTables",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# TFCL parser (reads existing file to include its strings in global lookup)
# ---------------------------------------------------------------------------

def parse_existing_tfcl(filepath: Path) -> Dict[str, dict]:
    """
    Parse tfcl_combined_lua.lua to extract verbose entries.
    Handles both the old compact-with-local-tables format and
    the global-lookup format.
    """
    if not filepath.exists():
        return {}

    content = filepath.read_text(encoding="utf-8", errors="ignore")
    entries: Dict[str, dict] = {}

    # ---- Global lookup format (Data block, no Sources block) ----
    if "Data = {" in content and "Sources" not in content[:200]:
        pat = re.compile(
            r'\["(\d{17})"\]\s*=\s*\{\s*(\d+)\s*,\s*([^,}]+)\s*,\s*([^,}]+)\s*,\s*([^,}]+)\s*,\s*([^}]+)\s*\}'
        )
        for m in pat.finditer(content):
            entries[m.group(1)] = {
                "Name":   m.group(6).strip().strip('"'),
                "Reason": m.group(4).strip().strip('"'),
                "Source": m.group(3).strip().strip('"'),
                "Static": m.group(5).strip().strip('"'),
                "Flags":  int(m.group(2)),
            }
        return entries

    # ---- Old format with local Sources/Reasons lookup tables ----
    local_sources: Dict[int, str] = {}
    local_reasons: Dict[int, str] = {}

    src_block = re.search(r"Sources\s*=\s*\{([^}]+)\}", content, re.DOTALL)
    if src_block:
        for m in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]*)"', src_block.group(1)):
            local_sources[int(m.group(1))] = m.group(2)

    rsn_block = re.search(r"Reasons\s*=\s*\{([^}]+)\}", content, re.DOTALL)
    if rsn_block:
        for m in re.finditer(r'\[(\d+)\]\s*=\s*"([^"]*)"', rsn_block.group(1)):
            local_reasons[int(m.group(1))] = m.group(2)

    # Data entries: flags, source_id, reason_id, "name", timestamp
    pat = re.compile(
        r'\["(\d{17})"\]\s*=\s*\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*"([^"]*)"\s*,\s*(\d+)\s*\}'
    )
    for m in pat.finditer(content):
        sid        = m.group(1)
        flags      = int(m.group(2))
        source_id  = int(m.group(3))
        reason_id  = int(m.group(4))
        name       = m.group(5)
        source_str = local_sources.get(source_id, f"source_{source_id}")
        reason_str = local_reasons.get(reason_id, f"reason_{reason_id}")
        entries[sid] = {
            "Name":   name,
            "Reason": reason_str,
            "Source": source_str,
            "Static": "tfcl_combined",
            "Flags":  flags,
        }

    return entries


# ---------------------------------------------------------------------------
# Source definitions
# ---------------------------------------------------------------------------
# Sources that produce individual embedded files
INDIVIDUAL_SOURCES = [
    {
        "name":          "d3fc0n6 Cheater List",
        "url":           "https://raw.githubusercontent.com/d3fc0n6/CheaterList/main/CheaterFriend/64ids",
        "parser":        "raw64",
        "source_label":  "d3fc0n6 Cheater List",
        "static_id":     "d3_cheat",
        "default_reason":"Cheater (d3fc0n6)",
        "output":        "d3fc0n6_embedded.lua",
        "weight":        60,
    },
    {
        "name":          "qfoxb Player List",
        "url":           "https://raw.githubusercontent.com/qfoxb/tf2bd-lists/main/playerlist.qfoxb.json",
        "parser":        "tf2bd",
        "source_label":  "qfoxb Player List",
        "static_id":     "qfoxb",
        "default_reason":"Cheater (qfoxb)",
        "output":        "qfoxb_embedded.lua",
        "weight":        55,
    },
    {
        "name":          "joekiller Player List",
        "url":           "https://raw.githubusercontent.com/joekiller/joekiller-list/main/playerlist.joekiller.json",
        "parser":        "tf2bd",
        "source_label":  "joekiller Player List",
        "static_id":     "joekiller",
        "default_reason":"Cheater (joekiller)",
        "output":        "joekiller_embedded.lua",
        "weight":        55,
    },
    {
        "name":          "Sleepy Main List",
        "url":           "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.sleepy.json",
        "parser":        "tf2bd",
        "source_label":  "Sleepy Main List",
        "static_id":     "sleepy_main",
        "default_reason":"Cheater (Sleepy)",
        "output":        "sleepy_main_embedded.lua",
        "weight":        65,
    },
    {
        "name":          "Sleepy External List",
        "url":           "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.sleepy-external.json",
        "parser":        "tf2bd",
        "source_label":  "Sleepy External List",
        "static_id":     "sleepy_ext",
        "default_reason":"Cheater (Sleepy External)",
        "output":        "sleepy_ext_embedded.lua",
        "weight":        40,
    },
    {
        "name":          "Sleepy Nullc0re List",
        "url":           "https://raw.githubusercontent.com/surepy/tf2db-sleepy-list/main/playerlist.nullc0re.json",
        "parser":        "tf2bd",
        "source_label":  "Sleepy Nullc0re List",
        "static_id":     "sleepy_nullc0re",
        "default_reason":"Cheater (Sleepy/nullc0re)",
        "output":        "sleepy_nullc0re_embedded.lua",
        "weight":        65,
    },
    {
        "name":          "TF2BD Official",
        "url":           "https://raw.githubusercontent.com/PazerOP/tf2_bot_detector/master/staging/cfg/playerlist.official.json",
        "parser":        "tf2bd",
        "source_label":  "TF2BD Official",
        "static_id":     "tf2bd_off",
        "default_reason":"Bot (TF2BD Official)",
        "output":        "tf2bd_official_embedded.lua",
        "weight":        75,
    },
    {
        "name":          "MegaScaterbomb",
        "url":           "https://raw.githubusercontent.com/ill5-com/megascatterbomb-tf2-cheater-database/main/megascatterbomb-tf2-cheater-database.min.json",
        "parser":        "megascat",
        "source_label":  "MegaScaterbomb",
        "static_id":     "mega_scat",
        "default_reason":"MegaScaterbomb (cheater)",
        "output":        "megascat_embedded.lua",
        "weight":        78,
    },
]

# Sources that feed only into the combined file (kept live by the Lua fetcher)
COMBINED_ONLY_SOURCES = [
    {
        "name":          "TF2BD Community Biglist",
        "url":           "https://raw.githubusercontent.com/ClusterConsultant/TF2BD-Community-Lists/main/playerlist.biglist.json",
        "parser":        "tf2bd",
        "source_label":  "TF2BD Community Biglist",
        "static_id":     "cc_biglist",
        "default_reason":"Bot (TF2BD Community Biglist)",
        "weight":        29,
    },
    {
        "name":          "TF2BD Community Trusted",
        "url":           "https://raw.githubusercontent.com/ClusterConsultant/TF2BD-Community-Lists/main/playerlist.trusted.json",
        "parser":        "tf2bd",
        "source_label":  "TF2BD Community Trusted",
        "static_id":     "cc_trusted",
        "default_reason":"Cheater (TF2BD Trusted)",
        "weight":        80,
    },
]


# ---------------------------------------------------------------------------
# Fetch + parse dispatcher
# ---------------------------------------------------------------------------

def fetch_and_parse(source: dict) -> Optional[Dict[str, dict]]:
    print(f"  [FETCH] {source['name']} ...")
    try:
        raw = fetch_url(source["url"])
    except Exception as exc:
        print(f"  [ERROR] Fetch failed: {exc}")
        return None

    parser = source["parser"]
    try:
        if parser == "raw64":
            entries = parse_raw64(raw, source)
        elif parser == "tf2bd":
            entries = parse_tf2bd(raw, source)
        elif parser == "megascat":
            entries = parse_megascat(raw, source)
        else:
            print(f"  [ERROR] Unknown parser: {parser}")
            return None
    except Exception as exc:
        print(f"  [ERROR] Parse failed: {exc}")
        return None

    print(f"  [OK]    {len(entries):,} entries")
    return entries


# ---------------------------------------------------------------------------
# Weight-based merge helper
# ---------------------------------------------------------------------------

def merge_into(combined: Dict[str, dict], incoming: Dict[str, dict]) -> Tuple[int, int]:
    """
    Merge `incoming` into `combined` using weight-based selection.
    Returns (new_count, overridden_count).
    """
    new_count = overridden_count = 0
    for sid, entry in incoming.items():
        existing = combined.get(sid)
        if existing is None:
            combined[sid] = dict(entry)
            new_count += 1
        elif should_override(existing, entry):
            combined[sid] = dict(entry)
            overridden_count += 1
        else:
            # Keep existing (higher or equal weight) - update name if missing
            if existing.get("Name") in (None, "Unknown", "") and entry.get("Name") not in (None, "Unknown", ""):
                existing["Name"] = entry["Name"]
    return new_count, overridden_count


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description="Rebuild embedded Lua databases with weight-based normalization")
    ap.add_argument("--dry-run", action="store_true",
                    help="Fetch and process but do not write any files")
    args = ap.parse_args()

    if args.dry_run:
        print("[DRY-RUN] No files will be written.\n")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # -----------------------------------------------------------------------
    # Step 1: Fetch individual sources
    # -----------------------------------------------------------------------
    print("=" * 64)
    print("Step 1/4 — Fetching individual sources")
    print("=" * 64)

    individual_data: Dict[str, Dict[str, dict]] = {}   # source name → entries
    combined: Dict[str, dict] = {}                      # steamid → best entry

    # Process higher-weight sources first so they land in combined first;
    # lower-weight sources still go through should_override() to be safe.
    all_individual = sorted(INDIVIDUAL_SOURCES, key=lambda s: -s["weight"])

    for source in all_individual:
        print(f"\n[SOURCE] {source['name']}  (weight={source['weight']})")
        entries = fetch_and_parse(source)
        if entries is None:
            continue
        individual_data[source["name"]] = entries
        new, ov = merge_into(combined, entries)
        print(f"  [MERGE] +{new:,} new, {ov:,} overridden in combined")

    # -----------------------------------------------------------------------
    # Step 2: Fetch combined-only sources
    # -----------------------------------------------------------------------
    print("\n" + "=" * 64)
    print("Step 2/4 — Fetching combined-only sources")
    print("=" * 64)

    for source in sorted(COMBINED_ONLY_SOURCES, key=lambda s: -s["weight"]):
        print(f"\n[SOURCE] {source['name']}  (weight={source['weight']})")
        entries = fetch_and_parse(source)
        if entries is None:
            continue
        new, ov = merge_into(combined, entries)
        print(f"  [MERGE] +{new:,} new, {ov:,} overridden in combined")

    print(f"\n[COMBINED] {len(combined):,} unique players after weight-based merge")

    # -----------------------------------------------------------------------
    # Step 3: Build global lookup tables (include existing TFCL strings)
    # -----------------------------------------------------------------------
    print("\n" + "=" * 64)
    print("Step 3/4 — Building global lookup tables")
    print("=" * 64)

    all_verbose: Dict[str, Dict[str, dict]] = {}
    for source in INDIVIDUAL_SOURCES:
        key = source["name"]
        if key in individual_data:
            all_verbose[key] = individual_data[key]

    all_verbose["_combined"] = combined

    # Include existing TFCL strings so IDs stay valid for that untouched file
    tfcl_entries = parse_existing_tfcl(TFCL_FILE)
    if tfcl_entries:
        print(f"  [TFCL] Parsed {len(tfcl_entries):,} existing entries from {TFCL_FILE.name}")
        all_verbose["_tfcl"] = tfcl_entries
    else:
        print(f"  [TFCL] {TFCL_FILE.name} not found or empty — skipping")

    src_m, rsn_m, stc_m, nme_m = build_global_lookup(all_verbose)
    print(f"  Sources : {len(src_m):,}")
    print(f"  Reasons : {len(rsn_m):,}")
    print(f"  Statics : {len(stc_m):,}")
    print(f"  Names   : {len(nme_m):,}  (>=4 occurrences)")

    # -----------------------------------------------------------------------
    # Step 4: Write files
    # -----------------------------------------------------------------------
    print("\n" + "=" * 64)
    print("Step 4/4 — Writing Lua files")
    print("=" * 64)

    if args.dry_run:
        for source in INDIVIDUAL_SOURCES:
            key = source["name"]
            if key in individual_data:
                print(f"  [DRY] Would write {source['output']}  ({len(individual_data[key]):,} entries)")
        print(f"  [DRY] Would write external_combined_embedded.lua  ({len(combined):,} entries)")
        print(f"  [DRY] Would write global_lookup_tables.lua")
        print("\nDry run complete. No files changed.")
        return

    # Individual per-source files
    for source in INDIVIDUAL_SOURCES:
        key = source["name"]
        if key not in individual_data:
            print(f"  [SKIP] {source['output']} (fetch failed)")
            continue
        out_path = OUTPUT_DIR / source["output"]
        write_individual_file(
            out_path, source["name"], source["url"],
            individual_data[key],
            src_m, rsn_m, stc_m, nme_m,
        )
        print(f"  [SAVED] {out_path.name}  ({len(individual_data[key]):,} entries)")

    # Combined file
    combined_path = OUTPUT_DIR / "external_combined_embedded.lua"
    write_individual_file(
        combined_path,
        "External Sources Combined",
        "d3fc0n6 + qfoxb + joekiller + sleepy (main/ext/nullc0re) + tf2bd_official + megascat + cc_biglist + cc_trusted",
        combined,
        src_m, rsn_m, stc_m, nme_m,
    )
    print(f"  [SAVED] {combined_path.name}  ({len(combined):,} entries)")

    # Global lookup tables
    lookup_path = OUTPUT_DIR / "global_lookup_tables.lua"
    write_global_lookup(lookup_path, src_m, rsn_m, stc_m, nme_m, len(all_verbose))
    print(f"  [SAVED] {lookup_path.name}")

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------
    print("\n" + "=" * 64)
    print("Done!")
    print("=" * 64)

    total = sum(len(v) for k, v in all_verbose.items() if not k.startswith("_"))
    print(f"  Sources fetched : {len(individual_data)}/{len(INDIVIDUAL_SOURCES)}")
    print(f"  Total raw rows  : {total:,}")
    print(f"  Combined unique : {len(combined):,}")
    print(f"  Files written   : {len(individual_data) + 2}  (+global_lookup, +combined)")

    # Show reason-weight distribution for combined
    print("\n  Reason weight distribution (combined):")
    buckets: Counter = Counter()
    for e in combined.values():
        w = score_reason(e.get("Reason"))
        if w >= 90:
            label = "90-100 (hard cheat / VAC)"
        elif w >= 75:
            label = "75-89  (trusted list cheater)"
        elif w >= 50:
            label = "50-74  (community cheater)"
        elif w >= 15:
            label = "15-49  (bot / suspicious)"
        else:
            label = "0-14   (generic / unknown)"
        buckets[label] += 1
    for label, count in sorted(buckets.items()):
        print(f"    {label} : {count:,}")


if __name__ == "__main__":
    main()
