# Resolver Lookup Findings

## Test setup
- 1v1 local server, same floor level ~500 units apart
- Enemy resolver: 6 known cycle positions, tested via `F` key
- Our head offset: 8 × 45° segments, cycled via `R` key
- Detection: `CTEFireBullets` triggers shot slot, `player_hurt` resolves it, expired slot = miss
- Fake yaw: **pure forward** — fake points straight at target, no offset
- Previous bias (+45°) data discarded

> ⚠️ **ALL DATA SHOULD BE TREATED AS PRELIMINARY**
> Local/listen server has unreliable viewangle updates — angles sometimes stale or not updating between ticks, which directly affects both the AA application and which resolver position is actually active. Several sessions had confirmed broken angle states. For trustworthy results, re-run all tests on a **dedicated community server** with proper tick rate and networked player state.

---

## default(0) — enemy shoots exactly where visible yaw points (no resolver offset)

| Head offset | M   | B   | H   | Verdict                      |
| ----------- | --- | --- | --- | ---------------------------- |
| toward(0)   | 0   | 9   | 3   | ⚠️ mostly body, occasional HS |
| +45(45)     | 0   | 10  | 0   | ✅ pure body (survivable)     |
| right(90)   | 5   | 2   | 1   | ✅ mostly miss/body           |
| +135(135)   | 3   | 0   | 0   | ✅ pure miss                  |
| away(180)   | 29  | 1   | 0   | ✅ pure miss                  |
| -135(225)   | 2   | 0   | 0   | ✅ pure miss                  |
| left(270)   | 0   | 4   | 4   | ❌ mixed body/headshot        |
| -45(315)    | 0   | 1   | 4   | ❌ headshot dominant          |

### Summary for default(0)
- **Best safe offsets:** `away(180)`, `+135(135)`, `-135(225)` — consistent pure miss
- **Acceptable:** `right(90)` — mostly miss/body; `+45(45)` — pure body, never HS
- **Risky:** `toward(0)` — mostly body but occasional HS
- **Avoid:** `left(270)`, `-45(315)` — headshot heavy

---

## left(-90) — enemy resolver shoots 90° left of visible yaw

| Head offset | M   | B   | H   | Verdict                     |
| ----------- | --- | --- | --- | --------------------------- |
| toward(0)   | 0   | 0   | 0   | ✅ no shots fired (untested) |
| +45(45)     | 4   | 7   | 0   | ✅ miss/body, never HS       |
| right(90)   | 2   | 0   | 0   | ✅ pure miss                 |
| +135(135)   | 3   | 0   | 0   | ✅ pure miss                 |
| away(180)   | 3   | 0   | 0   | ✅ pure miss                 |
| -135(225)   | 3   | 0   | 0   | ✅ pure miss                 |
| left(270)   | 0   | 0   | 4   | ❌ pure headshot             |
| -45(315)    | 1   | 0   | 0   | ✅ pure miss                 |

### Summary for left(-90)
- **Avoid:** `left(270)` — pure headshot
- **Safe:** everything else — miss or body dominant
- **Best:** right arc (`right(90)` through `-135(225)`) and `-45(315)` — pure miss

---

## right(90) — enemy resolver shoots 90° right of visible yaw

| Head offset | M   | B   | H   | Verdict                      |
| ----------- | --- | --- | --- | ---------------------------- |
| toward(0)   | 6   | 0   | 0   | ✅ pure miss                  |
| +45(45)     | 12  | 0   | 0   | ✅ pure miss                  |
| right(90)   | 0   | 0   | 10  | ❌ pure headshot              |
| +135(135)   | 0   | 0   | 11  | ❌ pure headshot              |
| away(180)   | 0   | 0   | 8   | ❌ pure headshot              |
| -135(225)   | 0   | 2   | 6   | ❌ headshot dominant          |
| left(270)   | 6   | 0   | 1   | ✅ mostly miss (1 HS outlier) |
| -45(315)    | 13  | 0   | 0   | ✅ pure miss                  |

### Summary for right(90)
- **Avoid:** `right(90)`, `+135(135)`, `away(180)`, `-135(225)` — right/rear arc all headshots
- **Safe:** `toward(0)`, `+45(45)`, `-45(315)` — pure miss
- **Notable:** danger zone is exactly mirrored vs `left(-90)` as expected

---

## invert(180) — enemy resolver shoots 180° opposite of visible yaw

> ⚠️ **Caveat:** viewangles were broken/stale on the test server during this session (same issue affected `default`). Results should be re-verified on a community server with stable viewangle updates before trusting.

| Head offset | M   | B   | H   | Verdict                  |
| ----------- | --- | --- | --- | ------------------------ |
| toward(0)   | 0   | 0   | 13  | ❌ pure headshot          |
| +45(45)     | 0   | 0   | 10  | ❌ pure headshot          |
| right(90)   | 0   | 9   | 0   | ⚠️ pure body (survivable) |
| +135(135)   | 0   | 3   | 0   | ⚠️ pure body (survivable) |
| away(180)   | 0   | 4   | 0   | ⚠️ pure body (survivable) |
| -135(225)   | 0   | 2   | 0   | ⚠️ pure body (survivable) |
| left(270)   | 0   | 5   | 0   | ⚠️ pure body (survivable) |
| -45(315)    | 0   | 3   | 2   | ❌ mixed body/headshot    |

### Summary for invert(180)
- **Avoid:** `toward(0)`, `+45(45)` — pure headshot; `-45(315)` — mixed
- **No pure miss found** — invert resolver hits everything, best case is body
- **Body zone:** `right(90)` through `left(270)` arc — survivable but always takes damage
- **Needs re-test** on community server with reliable viewangle updates

---

## forward(0) — enemy resolver shoots straight at our visible yaw (same as default but forced)

> ⚠️ **Caveat:** `forward` and `default` share the same angle — fake yaw position has notable impact on results here. Re-test with different fake biases for full confidence.

| Head offset | M   | B   | H   | Verdict                   |
| ----------- | --- | --- | --- | ------------------------- |
| toward(0)   | 1   | 8   | 6   | ❌ mixed, HS heavy         |
| +45(45)     | 0   | 8   | 0   | ⚠️ pure body (survivable)  |
| right(90)   | 4   | 6   | 0   | ⚠️ miss/body mix           |
| +135(135)   | 9   | 0   | 0   | ✅ pure miss               |
| away(180)   | 8   | 0   | 0   | ✅ pure miss               |
| -135(225)   | 4   | 0   | 0   | ✅ pure miss               |
| left(270)   | 6   | 11  | 16  | ❌ very mixed, HS dominant |
| -45(315)    | 0   | 2   | 4   | ❌ headshot dominant       |

### Summary for forward(0)
- **Best safe offsets:** `+135(135)`, `away(180)`, `-135(225)` — pure miss (mirrors default(0))
- **Acceptable:** `right(90)` — no HS; `+45(45)` — pure body
- **Avoid:** `left(270)`, `-45(315)`, `toward(0)` — headshot risk
- **Needs more testing** — fake yaw visibly affects resolver behavior here

---

## back(180) — enemy resolver shoots 180° behind visible yaw (same angle as invert but forced)

| Head offset | M   | B   | H   | Verdict                  |
| ----------- | --- | --- | --- | ------------------------ |
| toward(0)   | 0   | 0   | 6   | ❌ pure headshot          |
| +45(45)     | 0   | 1   | 7   | ❌ headshot dominant      |
| right(90)   | 0   | 9   | 0   | ⚠️ pure body (survivable) |
| +135(135)   | 1   | 5   | 0   | ⚠️ body/miss              |
| away(180)   | 0   | 6   | 0   | ⚠️ pure body (survivable) |
| -135(225)   | 0   | 9   | 0   | ⚠️ pure body (survivable) |
| left(270)   | 0   | 2   | 0   | ⚠️ pure body (low sample) |
| -45(315)    | 0   | 1   | 8   | ❌ headshot dominant      |

### Summary for back(180)
- **Avoid:** `toward(0)`, `+45(45)`, `-45(315)` — headshot heavy
- **No pure miss found** — mirrors `invert(180)`, rear arc is body at best
- **Body zone:** `right(90)` through `left(270)` arc — all body, zero HS
- **Notable:** exact same pattern as `invert(180)` — front arc (`toward`, `+45`, `-45`) = HS; sides/rear = body

---

## Other resolver positions
Not yet tested. Reset table with `H`, set expected with `F`, collect data, press `G` to dump.

---

## Notes
- `M` = miss (AA angle dodged the shot entirely)
- `B` = body hit (dmg=50, survived)
- `H` = headshot (dmg=150, lethal)
- Fake yaw bias during this test: **none** — fake points straight at target
- `0M 0B 0H` = enemy never fired during that offset — not a confirmed miss, just untested
