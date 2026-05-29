#!/usr/bin/env python3
"""
validate_database.py

Scan all embedded SteamIDs (least data / likely abandoned first), verify via:
  - Steam Web API (GetPlayerSummaries + GetPlayerBans) — keys from local steamkeys/
  - SteamHistory API — keys from local steamhsitoryapiki (optional)

Writes (never commit API keys):
  - build_removals.txt   — deleted / invalid accounts (excluded on rebuild)
  - build_overlay.json   — VAC / community-ban / name upgrades (merged on rebuild)

Then run:  python rebuild_embedded_databases.py

Usage:
    python validate_database.py --dry-run
    python validate_database.py --limit 500
    python validate_database.py
"""

from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from rebuild_embedded_databases import (
    BUILD_OVERLAY_PATH,
    BUILD_REMOVALS_PATH,
    LOOKUP_FILE,
    OUTPUT_DIR,
    UNIFIED_OUTPUT,
    compute_data_richness,
    load_all_embed_entries,
    load_build_overlay,
    load_build_removals,
    parse_embed_lua_file,
    parse_global_lookup,
    should_override,
    sid64_valid,
)

# ---------------------------------------------------------------------------
# Defaults (local only — not in repo)
# ---------------------------------------------------------------------------
DEFAULT_STEAM_KEYS_DIR = Path(
    r"C:\Steam\steamapps\common\Team Fortress 2\Lua Cheater_Detection\steamkeys"
)
DEFAULT_STEAMHISTORY_KEYS = Path(
    r"C:\Steam\steamapps\common\Team Fortress 2\Lua Cheater_Detection\steamhsitoryapiki"
)  # directory: api.txt, api2.txt (one key per file or line)
CHECKPOINT_PATH = Path(__file__).parent / "validate_checkpoint.json"

STEAM_SUMMARIES_URL = "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v0002/"
STEAM_BANS_URL = "https://api.steampowered.com/ISteamUser/GetPlayerBans/v1/"
STEAMHISTORY_URL = "https://steamhistory.net/api/sourcebans"

FLAG_VAC = 32
FLAG_COMM = 16
BATCH_SIZE = 100
REQUEST_GAP_SEC = 0.35
HTTP_MAX_RETRIES = 4
HTTP_BACKOFF_SEC = 45


def load_key_list(path: Path) -> List[str]:
    """Load API keys from a file or every file in a directory (one key per line)."""
    keys: List[str] = []
    if not path.exists():
        return keys

    files: List[Path] = []
    if path.is_dir():
        files = sorted(p for p in path.iterdir() if p.is_file())
    else:
        files = [path]

    for fp in files:
        try:
            text = fp.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if len(line) >= 16:
                keys.append(line)
    return keys


def describe_key_source(path: Path, keys: List[str]) -> str:
    if not path.exists():
        return f"missing ({path})"
    if path.is_dir():
        files = sorted(p.name for p in path.iterdir() if p.is_file())
        return f"{len(keys)} from {path.name}/ ({', '.join(files) if files else 'no files'})"
    return f"{len(keys)} from {path.name}"


class KeyPool:
    def __init__(self, keys: List[str], label: str) -> None:
        self.keys = keys
        self.label = label
        self.index = 0

    def next_key(self) -> Optional[str]:
        if not self.keys:
            return None
        key = self.keys[self.index % len(self.keys)]
        self.index += 1
        return key


def http_get_json(url: str, timeout: int = 45) -> Optional[dict]:
    req = urllib.request.Request(url, headers={"User-Agent": "CheaterDetection-DBValidate/1.0"})
    for attempt in range(HTTP_MAX_RETRIES):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8", errors="replace"))
        except urllib.error.HTTPError as exc:
            if exc.code in (429, 503) and attempt + 1 < HTTP_MAX_RETRIES:
                wait = HTTP_BACKOFF_SEC * (attempt + 1)
                print(f"  [HTTP] {exc.code} rate limited — backing off {wait}s (attempt {attempt + 1}/{HTTP_MAX_RETRIES})")
                time.sleep(wait)
                continue
            print(f"  [HTTP] {exc}")
            return None
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
            if attempt + 1 < HTTP_MAX_RETRIES:
                wait = min(HTTP_BACKOFF_SEC, 5 * (attempt + 1))
                print(f"  [HTTP] {exc} — retry in {wait}s")
                time.sleep(wait)
                continue
            print(f"  [HTTP] {exc}")
            return None
    return None


def fetch_player_summaries(steam_ids: List[str], pool: KeyPool) -> Dict[str, dict]:
    key = pool.next_key()
    if not key:
        return {}
    url = STEAM_SUMMARIES_URL + "?" + urllib.parse.urlencode({
        "key": key,
        "steamids": ",".join(steam_ids),
    })
    data = http_get_json(url)
    if not data:
        return {}
    out: Dict[str, dict] = {}
    for player in data.get("response", {}).get("players", []):
        sid = str(player.get("steamid", ""))
        if sid64_valid(sid):
            out[sid] = player
    return out


def fetch_player_bans(steam_ids: List[str], pool: KeyPool) -> Dict[str, dict]:
    key = pool.next_key()
    if not key:
        return {}
    url = STEAM_BANS_URL + "?" + urllib.parse.urlencode({
        "key": key,
        "steamids": ",".join(steam_ids),
    })
    data = http_get_json(url)
    if not data:
        return {}
    out: Dict[str, dict] = {}
    for row in data.get("players", []):
        sid = str(row.get("SteamId", row.get("steamid", "")))
        if sid64_valid(sid):
            out[sid] = row
    return out


def fetch_steamhistory(steam_ids: List[str], pool: KeyPool) -> Dict[str, dict]:
    key = pool.next_key()
    if not key:
        return {}
    url = STEAMHISTORY_URL + "?" + urllib.parse.urlencode({
        "key": key,
        "shouldkey": "0",
        "steamids": ",".join(steam_ids),
    })
    data = http_get_json(url)
    if not data:
        return {}
    response = data.get("response") if isinstance(data.get("response"), dict) else data
    players = response.get("players") if isinstance(response, dict) else None
    if isinstance(players, list):
        out: Dict[str, dict] = {}
        for row in players:
            if isinstance(row, dict):
                sid = str(row.get("steamid", row.get("SteamId", "")))
                if sid64_valid(sid):
                    out[sid] = row
        return out
    if isinstance(players, dict):
        return {k: v for k, v in players.items() if sid64_valid(k) and isinstance(v, dict)}
    return {}


def economy_ban_active(value: object) -> bool:
    if not isinstance(value, str):
        return False
    lower = value.strip().lower()
    return lower not in ("", "none", "no")


def load_scan_entries() -> Dict[str, dict]:
    """Load IDs to scan — prefer unified bundle (one row per player)."""
    lookup = parse_global_lookup(LOOKUP_FILE)
    unified_path = OUTPUT_DIR / UNIFIED_OUTPUT
    if unified_path.exists():
        entries = parse_embed_lua_file(unified_path, lookup)
        if entries:
            return entries
    return load_all_embed_entries()


def account_exists(summary: Optional[dict], ban_row: Optional[dict]) -> bool:
    """Steam Web API: profile missing from both endpoints = deleted/invalid."""
    return summary is not None or ban_row is not None


def sort_ids_by_richness(entries: Dict[str, dict]) -> List[str]:
    """Least data first (abandoned/raw IDs), richest profiles last."""
    return sorted(
        entries.keys(),
        key=lambda sid: (compute_data_richness(entries[sid]), sid),
    )


def load_checkpoint() -> dict:
    if not CHECKPOINT_PATH.exists():
        return {"processed": [], "removals": [], "overlay": {}}
    try:
        return json.loads(CHECKPOINT_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {"processed": [], "removals": [], "overlay": {}}


def save_checkpoint(state: dict) -> None:
    CHECKPOINT_PATH.write_text(json.dumps(state, indent=2), encoding="utf-8")


def build_upgrade(existing: dict, name: Optional[str], vac: bool, comm: bool) -> Optional[dict]:
    flags = int(existing.get("Flags") or 0)
    new_flags = flags
    if vac:
        new_flags |= FLAG_VAC
    if comm:
        new_flags |= FLAG_COMM

    if vac:
        candidate = {
            "Name": name or existing.get("Name") or "Unknown",
            "Reason": "VAC Ban",
            "Source": "Steam API Validation",
            "Static": "vac_ban",
            "Flags": new_flags,
        }
        if should_override(existing, candidate) or new_flags != flags:
            return candidate

    if comm:
        candidate = {
            "Name": name or existing.get("Name") or "Unknown",
            "Reason": "Community Ban",
            "Source": "Steam API Validation",
            "Static": existing.get("Static") or "unknown",
            "Flags": new_flags,
        }
        if should_override(existing, candidate) or new_flags != flags:
            return candidate

    if name and name != "Unknown" and (existing.get("Name") or "Unknown") == "Unknown":
        candidate = dict(existing)
        candidate["Name"] = name
        candidate["Flags"] = new_flags
        return candidate

    return None


def process_batch(
    batch: List[str],
    entries: Dict[str, dict],
    steam_pool: KeyPool,
    history_pool: KeyPool,
    removals: set,
    overlay: Dict[str, dict],
    request_gap: float = REQUEST_GAP_SEC,
) -> Tuple[int, int, int]:
    removed = upgraded = alive = 0

    summaries = fetch_player_summaries(batch, steam_pool)
    time.sleep(request_gap)
    bans = fetch_player_bans(batch, steam_pool)
    time.sleep(request_gap)
    # SteamHistory only for live accounts (VAC/comm/name enrichment)
    history: Dict[str, dict] = {}
    if history_pool.keys:
        history = fetch_steamhistory(batch, history_pool)
        time.sleep(request_gap)

    for sid in batch:
        existing = entries[sid]
        summary = summaries.get(sid)
        ban_row = bans.get(sid)

        # Step 1: account must exist (Steam Web API is authoritative for deletion)
        if not account_exists(summary, ban_row):
            removals.add(sid)
            overlay.pop(sid, None)
            removed += 1
            continue

        alive += 1
        hist_row = history.get(sid)

        # Step 2: scrape display name (summary first, SteamHistory fallback)
        name = None
        if summary:
            name = (summary.get("personaname") or "").strip() or None

        # Step 3: VAC / community ban flags (Steam bans API + SteamHistory)
        vac = False
        comm = False
        if ban_row:
            vac = bool(ban_row.get("VACBanned")) or int(ban_row.get("NumberOfVACBans") or 0) > 0
            comm = bool(ban_row.get("CommunityBanned"))
            if economy_ban_active(ban_row.get("EconomyBan")):
                comm = True

        if hist_row:
            vac = vac or bool(hist_row.get("VACBanned") or hist_row.get("vacBanned") or hist_row.get("vacbanned"))
            comm = comm or bool(hist_row.get("CommunityBanned") or hist_row.get("communityBanned"))
            if economy_ban_active(hist_row.get("EconomyBan") or hist_row.get("economyBan")):
                comm = True
            if not name:
                name = (hist_row.get("personaname") or hist_row.get("name") or "").strip() or None

        upgrade = build_upgrade(existing, name, vac, comm)
        if upgrade:
            overlay[sid] = upgrade
            upgraded += 1

    return removed, upgraded, alive


def print_richness_histogram(entries: Dict[str, dict], ordered: List[str]) -> None:
    buckets: Dict[str, int] = {"0-19": 0, "20-39": 0, "40-59": 0, "60-79": 0, "80+": 0}
    for sid in ordered:
        r = compute_data_richness(entries[sid])
        if r < 20:
            buckets["0-19"] += 1
        elif r < 40:
            buckets["20-39"] += 1
        elif r < 60:
            buckets["40-59"] += 1
        elif r < 80:
            buckets["60-79"] += 1
        else:
            buckets["80+"] += 1
    print("  Richness histogram (scan order: low -> high):")
    for label in ("0-19", "20-39", "40-59", "60-79", "80+"):
        print(f"    {label:6s} : {buckets[label]:,}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Validate embedded DB SteamIDs and write build overlay/removals")
    ap.add_argument("--dry-run", action="store_true", help="Sort + stats only, no HTTP")
    ap.add_argument("--limit", type=int, default=0, help="Max IDs to scan (0 = all)")
    ap.add_argument("--resume", action="store_true", help="Continue from validate_checkpoint.json")
    ap.add_argument("--request-gap", type=float, default=REQUEST_GAP_SEC,
                    help="Seconds between API calls (default: safe for single Steam key)")
    ap.add_argument("--steam-keys-dir", type=Path, default=DEFAULT_STEAM_KEYS_DIR)
    ap.add_argument("--steamhistory-keys", type=Path, default=DEFAULT_STEAMHISTORY_KEYS)
    args = ap.parse_args()

    if not LOOKUP_FILE.exists():
        print(f"[ERROR] Missing {LOOKUP_FILE} — run rebuild_embedded_databases.py first.")
        return

    print("=" * 64)
    print("Loading embedded entries...")
    entries = load_scan_entries()
    print(f"  {len(entries):,} unique SteamIDs loaded (from unified embed)")

    ordered = sort_ids_by_richness(entries)
    print_richness_histogram(entries, ordered)
    print(f"  First to scan (sparse): {ordered[0]}  richness={compute_data_richness(entries[ordered[0]])}")
    print(f"  Last to scan (rich):    {ordered[-1]}  richness={compute_data_richness(entries[ordered[-1]])}")

    if args.limit > 0:
        ordered = ordered[: args.limit]
        print(f"  --limit {args.limit}: scanning subset only")

    if args.dry_run:
        print("\n[DRY-RUN] No HTTP requests. Remove --dry-run to validate.")
        return

    steam_keys = load_key_list(args.steam_keys_dir)
    history_keys = load_key_list(args.steamhistory_keys)
    if not steam_keys:
        print(f"\n[ERROR] No Steam Web API keys in {args.steam_keys_dir}")
        print("        Add one key per line in that folder, then re-run.")
        return

    print(f"\n  Steam Web API keys     : {describe_key_source(args.steam_keys_dir, steam_keys)}")
    print(f"  SteamHistory API keys  : {describe_key_source(args.steamhistory_keys, history_keys)}")
    if not history_keys:
        print("        (optional — VAC/comm enrichment will use Steam Web API bans only)")

    steam_pool = KeyPool(steam_keys, "steam")
    history_pool = KeyPool(history_keys, "steamhistory")
    request_gap = max(0.2, args.request_gap)

    removals: set = set(load_build_removals())
    overlay: Dict[str, dict] = load_build_overlay()
    processed: set = set()

    if args.resume and CHECKPOINT_PATH.exists():
        ckpt = load_checkpoint()
        processed = set(ckpt.get("processed", []))
        removals = set(ckpt.get("removals", [])) | removals
        overlay.update(ckpt.get("overlay", {}))
        print(f"  Resumed: {len(processed):,} already processed")

    todo = [sid for sid in ordered if sid not in processed]
    est_batches = (len(todo) + BATCH_SIZE - 1) // BATCH_SIZE
    calls_per_batch = 2 + (1 if history_pool.keys else 0)
    print(f"\n  Scanning {len(todo):,} IDs in batches of {BATCH_SIZE} (~{est_batches:,} batches)")
    print(f"  API pacing: {request_gap}s gap, {calls_per_batch} calls/batch "
          f"(Steam x2 + SteamHistory x{1 if history_pool.keys else 0})")
    print(f"  Keys: {len(steam_keys)} Steam Web, {len(history_keys)} SteamHistory (round-robin)")

    total_removed = total_upgraded = total_alive = 0
    batch_num = 0

    for i in range(0, len(todo), BATCH_SIZE):
        batch = todo[i : i + BATCH_SIZE]
        batch_num += 1
        removed, upgraded, alive = process_batch(
            batch, entries, steam_pool, history_pool, removals, overlay, request_gap
        )
        total_removed += removed
        total_upgraded += upgraded
        total_alive += alive
        processed.update(batch)

        if batch_num == 1 or batch_num % 10 == 0 or i + BATCH_SIZE >= len(todo):
            print(
                f"  [{batch_num:4d}] processed {len(processed):,}/{len(ordered):,} | "
                f"dead {len(removals):,} | overlay {len(overlay):,}"
            )
        save_checkpoint({
            "processed": sorted(processed),
            "removals": sorted(removals),
            "overlay": overlay,
        })

        time.sleep(request_gap)

    BUILD_REMOVALS_PATH.write_text("\n".join(sorted(removals)) + "\n", encoding="utf-8")
    BUILD_OVERLAY_PATH.write_text(json.dumps(overlay, indent=2), encoding="utf-8")

    if CHECKPOINT_PATH.exists():
        CHECKPOINT_PATH.unlink()

    print("\n" + "=" * 64)
    print("Done")
    print("=" * 64)
    print(f"  Alive (kept)     : {total_alive:,}")
    print(f"  Dead (removals)  : {len(removals):,}  -> {BUILD_REMOVALS_PATH.name}")
    print(f"  Upgraded overlay : {len(overlay):,}  -> {BUILD_OVERLAY_PATH.name}")
    print("\n  Next:  python rebuild_embedded_databases.py")


if __name__ == "__main__":
    main()
