![Visitors](https://api.visitorbadge.io/api/visitors?path=https%3A%2F%2Fgithub.com%2Ftitaniummachine1%2FCheater_Detection&label=Visitors&countColor=%23263759&style=plastic)
![Stars](https://img.shields.io/github/stars/titaniummachine1/Cheater_Detection?style=plastic&logo=github&color=yellow)
![Forks](https://img.shields.io/github/forks/titaniummachine1/Cheater_Detection?style=plastic&logo=github)
![Commits](https://img.shields.io/github/commit-activity/m/titaniummachine1/Cheater_Detection?style=plastic&logo=git)
![Last Commit](https://img.shields.io/github/last-commit/titaniummachine1/Cheater_Detection?style=plastic&logo=github)
![Downloads](https://img.shields.io/github/downloads/titaniummachine1/Cheater_Detection/total?style=plastic&logo=github)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Release](https://github.com/titaniummachine1/Cheater_Detection/actions/workflows/release.yml/badge.svg)](https://github.com/titaniummachine1/Cheater_Detection/actions/workflows/release.yml)

# Cheater_Detection

<img width="534" height="460" alt="image" src="https://github.com/user-attachments/assets/a58ce056-6186-4ed8-bdd1-8397728e6889" />

Automatic bot and cheater detection with cheater prioritization, visuals based on RijiN, and an optional local HTTP bridge for smoother online lookups.

---

## Requirements

Click the badges below to download required dependencies:

[![LuaLib](https://img.shields.io/badge/Download-lnxLib-blue?style=for-the-badge&logo=github)](https://github.com/lnx00/Lmaobox-Library/releases/latest/)
_Copy `lnxLib.lua` to your `%localappdata%/lua` folder._

[![TimMenu](https://img.shields.io/badge/Download-TimMenu-blue?style=for-the-badge&logo=github)](https://github.com/titaniummachine1/TimMenu/releases/download/v1.8.8/TimMenu.lua)
_Copy `TimMenu.lua` to your `%localappdata%/lua` folder._

> [!NOTE]
> Python 3 is optional but highly recommended to run the local HTTP bridge middleware for asynchronous background fetches.

---

<img width="743" height="628" alt="image" src="https://github.com/user-attachments/assets/e007993a-cee0-44ac-8338-1657f94e78a4" />

<img width="536" height="651" alt="image" src="https://github.com/user-attachments/assets/83103a3a-81c2-4943-b236-ad923cdb6073" />

<img width="643" height="744" alt="image" src="https://github.com/user-attachments/assets/41e758f9-a837-4d6e-ab0a-61e9a8f87f46" />

> [!IMPORTANT]
>
> ### ✅ Current Active Detections Status
>
> **Everything except aimbot detections is now live and running.**
>
> - **Database Engine**: Fully functional, stable, and highly optimized.
> - **All static databases** (TF2BD Official/Trusted, Sleepy, Joekiller, Qfoxb, Masterbase broadcasts, etc.) are fully imported and active.
> - **Cheater prioritization**, auto-voting, and flagging using local records work instantly.
> - **Visual features** (ESP flags, RijiN-style cheater indicators), player lists, and modular features are fully operational.
> - Most behavioral/telemetry detections (anti-aim, bhop, duck speed, etc.) are active.
>
> **Aimbot detections** are currently the only module not yet live (under active development/restoration).

---

## 🚀 What's New in v4.0.0 (The Performance Update)

We have completely re-engineered the backend storage and in-memory execution pipeline to offer massive performance gains **entirely for free**:

- **Hybrid Lexical Database Compression**: Storing \~31,000+ cheater database records using pre-compiled integer IDs—saving **80-90%** of disk storage and Lua heap space (**reducing script RAM by 5-10 MB**).
- **Lazy Decompression**: Entries stay compressed in memory and are decompressed **only once** on-demand when a player joins the server.
- **Zero-Allocation Gameplay Path**: The high-frequency callback loops (such as `CreateMove` and `Draw`) perform direct lookups against active player cache states, allocating **zero tables** during frame rendering. This completely eliminates game micro-stutters and garbage collection spikes.
- **Instant Disk Saves**: Database flushing is optimized to complete in **\~200 ms** (down from several seconds of gameplay freeze).

---

## Download

[![Download Latest](https://img.shields.io/github/downloads/titaniummachine1/Cheater_Detection/total.svg?style=for-the-badge&logo=download&label=Download%20Latest)](https://github.com/titaniummachine1/Cheater_Detection/releases/latest/download/Cheater_Detection.lua)

Every push to `main` triggers [`.github/workflows/release.yml`](.github/workflows/release.yml): embedded DBs are rebuilt, Lua is bundled, a semver tag is bumped from the **first line of the commit message**, and a GitHub Release is published with:

| Bump | Version change | Keywords in commit (examples) |
|------|----------------|--------------------------------|
| **patch** (default) | `+0.0.1` | `fix`, `perf`, `patch`, `hotfix` — or no keyword |
| **minor** | `+0.1.0` (patch reset to 0) | `minor`, `feat`, `feature`, `update` |
| **major** | `+1.0.0` (minor/patch reset) | `major`, `breaking`, `break` |

Example: `v1.4.2` + commit `perf: faster bhop gate` → `v1.4.3`. Commit `update: new detections` → `v1.5.0`. Commit `major: rewrite evidence` → `v2.0.0`.

Legacy tags like `v1.4` are treated as `v1.4.0` before bumping.

- `Cheater_Detection.lua` (bundled script)
- `local_http_bridge_server.py` (optional bridge)
- `SHA256SUMS.txt`

Workflow artifacts are not kept (storage is purged after each run). To skip a release for a commit, include `[skip release]` in the commit message.

---

## Optional Local Bridge

Cheater Detection ships with an optional localhost HTTP bridge in the `LocalBridge` folder.

When the bridge is running:

- Online requests are processed asynchronously through the localhost promise-style bridge instead of blocking your gameplay.
- The Python bridge handles HTTP fetch streams on a background thread.
- Lua polls for results lazily and maintains connection state.

When the bridge is not running:

- The script safely runs in standard offline database fallback mode.
- Probe testing and online lookups are strictly throttled to unobtrusive windows (like when you are dead or on the main menu).

### Running The Bridge

1. Open `LocalBridge/StartLocalBridge.bat`.
2. Keep the command prompt window open in the background while you play.
3. Load Cheater Detection inside your menu.

---

## Project Layout

- `Cheater_Detection/services/http_queue.lua`: Owns the HTTP transport selection and fallback behavior.
- `LocalBridge/local_http_bridge_server.py`: Asynchronous localhost bridge server middleware.
- `LocalBridge/StartLocalBridge.bat`: Launcher utility for Windows users.

---

## Contact

- [Contact me on Telegram](https://t.me/TerminatorMachine)
- [Official Telegram Channel](https://t.me/TerminatorMachine)
