#!/usr/bin/env python3
"""
analyze_reason_evidence.py

Read every per-source embedded file + TFCL + unified winner.
For each SteamID, list ALL contributing reasons (not just merge winner),
sorted by reason weight then source weight.

Usage:
    python analyze_reason_evidence.py
    python analyze_reason_evidence.py --show-conflicts 25
    python analyze_reason_evidence.py --show-sid 76561198000000000
"""

from __future__ import annotations

import argparse
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from rebuild_embedded_databases import (
    LOOKUP_FILE,
    OUTPUT_DIR,
    TFCL_FILE,
    UNIFIED_OUTPUT,
    parse_embed_lua_file,
    parse_global_lookup,
    score_reason,
    score_source,
    should_override,
)

SCRIPT_DIR = Path(__file__).parent

# Per-source embeds written by rebuild (exclude unified / legacy combined rollup).
SOURCE_EMBED_FILES = [
    "d3fc0n6_embedded.lua",
    "qfoxb_embedded.lua",
    "joekiller_embedded.lua",
    "sleepy_main_embedded.lua",
    "sleepy_ext_embedded.lua",
    "sleepy_nullc0re_embedded.lua",
    "tf2bd_official_embedded.lua",
    "megascat_embedded.lua",
    "local_64ids_embedded.lua",
    "local_text_embedded.lua",
    "local_k13imz_embedded.lua",
]


def reason_bucket(reason: str) -> str:
    w = score_reason(reason)
    if w >= 110:
        return "valve"
    if w >= 105:
        return "bot"
    if w >= 90:
        return "vac/gameban"
    if w >= 75:
        return "trusted_cheater"
    if w >= 50:
        return "community_cheater"
    if w >= 30:
        return "suspicious"
    if w > 0:
        return "low_signal"
    return "generic"


def normalize_reason_key(reason: str) -> str:
    """Collapse attribute noise for dedupe analysis (not used for merge)."""
    base = reason.strip()
    base = re.sub(r"\s*\([^)]*\)\s*$", "", base)  # drop trailing (attrs)
    base = re.sub(r"\s+", " ", base)
    return base.lower()


def evidence_sort_key(row: dict) -> Tuple[int, int, str]:
    rw = score_reason(row.get("Reason"))
    sw = score_source(row.get("Static"))
    return (-rw, -sw, row.get("Reason") or "")


def pick_winner(rows: List[dict]) -> dict:
    winner = rows[0]
    for row in rows[1:]:
        if should_override(winner, row):
            winner = row
    return winner


def load_all_evidence(lookup: dict) -> Tuple[Dict[str, List[dict]], Dict[str, dict]]:
    by_sid: Dict[str, List[dict]] = defaultdict(list)

    for filename in SOURCE_EMBED_FILES:
        path = OUTPUT_DIR / filename
        rows = parse_embed_lua_file(path, lookup)
        label = filename.replace("_embedded.lua", "")
        for sid, entry in rows.items():
            by_sid[sid].append({
                **entry,
                "_from": label,
            })

    tfcl_rows = parse_embed_lua_file(TFCL_FILE, lookup)
    for sid, entry in tfcl_rows.items():
        by_sid[sid].append({**entry, "_from": "tfcl_combined"})

    unified = parse_embed_lua_file(OUTPUT_DIR / UNIFIED_OUTPUT, lookup)
    return by_sid, unified


def dedupe_rows(rows: List[dict]) -> List[dict]:
    seen = set()
    out: List[dict] = []
    for row in rows:
        key = (row.get("Reason"), row.get("Static"), row.get("_from"))
        if key in seen:
            continue
        seen.add(key)
        out.append(row)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Analyze multi-source reason evidence per player")
    ap.add_argument("--show-conflicts", type=int, default=20,
                    help="Print N most interesting multi-source conflicts")
    ap.add_argument("--show-sid", type=str, default="",
                    help="Dump full evidence stack for one SteamID")
    args = ap.parse_args()

    lookup = parse_global_lookup(LOOKUP_FILE)
    by_sid, unified = load_all_evidence(lookup)

    multi_source = 0
    multi_reason = 0
    bot_vs_cheater = 0
    tie_break_source = 0
    winner_mismatch = 0
    reason_strings = Counter()
    norm_reason_strings = Counter()

    conflict_samples: List[Tuple[int, str, List[dict], dict]] = []

    for sid, rows in by_sid.items():
        rows = dedupe_rows(rows)
        if len(rows) > 1:
            multi_source += 1

        reasons = {r.get("Reason") for r in rows}
        if len(reasons) > 1:
            multi_reason += 1

        for r in rows:
            reason_strings[r.get("Reason") or ""] += 1
            norm_reason_strings[normalize_reason_key(r.get("Reason") or "")] += 1

        sorted_rows = sorted(rows, key=evidence_sort_key)
        computed = pick_winner(sorted_rows)
        actual = unified.get(sid)

        buckets = {reason_bucket(r.get("Reason") or "") for r in rows}
        if "bot" in buckets and ("trusted_cheater" in buckets or "community_cheater" in buckets):
            bot_vs_cheater += 1

        if len(rows) >= 2:
            top_rw = score_reason(sorted_rows[0].get("Reason"))
            tied = [r for r in sorted_rows if score_reason(r.get("Reason")) == top_rw]
            if len(tied) > 1:
                tie_break_source += 1

        if actual and computed:
            if (actual.get("Reason"), actual.get("Static")) != (computed.get("Reason"), computed.get("Static")):
                winner_mismatch += 1

        if len(rows) >= 2 and ("bot" in buckets) != (len(buckets) == 1 and "bot" in buckets):
            score = len(rows) * 10 + (10 if "bot" in buckets else 0)
            conflict_samples.append((score, sid, sorted_rows, actual or {}))

    conflict_samples.sort(key=lambda x: (-x[0], x[1]))

    print("=" * 72)
    print("Reason evidence analysis (all per-source rows, unified = current winner)")
    print("=" * 72)
    print(f"  Players with 2+ source rows     : {multi_source:,}")
    print(f"  Players with 2+ distinct reasons: {multi_reason:,}")
    print(f"  Bot + cheater bucket overlap    : {bot_vs_cheater:,}")
    print(f"  Equal reason weight, source tie : {tie_break_source:,}")
    print(f"  Unified != recomputed winner    : {winner_mismatch:,}")
    print(f"  Unique reason strings (raw)     : {len(reason_strings):,}")
    print(f"  Unique normalized reason keys   : {len(norm_reason_strings):,}")
    print(f"  Unified embed entries           : {len(unified):,}")

    print("\n  Top normalized reason families:")
    for reason, count in norm_reason_strings.most_common(15):
        print(f"    {count:6,}  {reason}")

    print("\n  Reason weight buckets (all source rows, not unified):")
    bucket_ctr: Counter = Counter()
    for rows in by_sid.values():
        for r in rows:
            bucket_ctr[reason_bucket(r.get("Reason") or "")] += 1
    for label in ("valve", "bot", "vac/gameban", "trusted_cheater", "community_cheater",
                  "suspicious", "low_signal", "generic"):
        print(f"    {label:18s} : {bucket_ctr[label]:,}")

    if args.show_sid:
        sid = args.show_sid.strip()
        rows = dedupe_rows(by_sid.get(sid, []))
        print(f"\n--- Evidence stack for {sid} ---")
        if not rows:
            print("  (not in any per-source embed)")
        for i, r in enumerate(sorted(rows, key=evidence_sort_key), 1):
            rw = score_reason(r.get("Reason"))
            sw = score_source(r.get("Static"))
            print(f"  {i:2d}. rw={rw:3d} sw={sw:3d} [{r.get('_from')}] static={r.get('Static')}")
            print(f"      {r.get('Reason')}")
        u = unified.get(sid)
        if u:
            print(f"  UNIFIED: rw={score_reason(u.get('Reason'))} static={u.get('Static')}")
            print(f"           {u.get('Reason')}")

    if args.show_conflicts > 0:
        print(f"\n--- Sample multi-source stacks (top {args.show_conflicts}) ---")
        for _, sid, rows, actual in conflict_samples[: args.show_conflicts]:
            print(f"\n  {sid}  ({len(rows)} sources)")
            for i, r in enumerate(rows[:6], 1):
                rw = score_reason(r.get("Reason"))
                sw = score_source(r.get("Static"))
                print(f"    {i}. rw={rw:3d} sw={sw:2d} [{r.get('_from'):14s}] {r.get('Reason')[:70]}")
            if len(rows) > 6:
                print(f"    ... +{len(rows) - 6} more")
            if actual:
                print(f"    -> unified: [{actual.get('Static')}] {actual.get('Reason')[:70]}")


if __name__ == "__main__":
    main()
