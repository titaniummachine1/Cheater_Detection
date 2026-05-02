![Visitors](https://api.visitorbadge.io/api/visitors?path=https%3A%2F%2Fgithub.com%2Ftitaniummachine1%2FCheater_Detection&label=Visitors&countColor=%23263759&style=plastic)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)


# Cheater_Detection
![image](https://github.com/titaniummachine1/Cheater_Detection/assets/78664175/e8743c83-95fa-4a07-8c7e-050bbc4d0592)



## Description
Automatic bot and cheater detection with cheater prioritization, visuals based on Rijin, and an optional local HTTP bridge for smoother online lookups.


[In case of problems Contact me on Telegram](https://t.me/TerminatorMachine)
https://t.me/TerminatorMachine

## Requirements
Click on the buttons below to download the requirements. V

[![LuaLib](https://img.shields.io/badge/Download-Latest-blue?style=for-the-badge&logo=download)](https://github.com/lnx00/Lmaobox-Library/releases/latest/) and copy the `lnxLib.lua` file to your `%localappdata%` folder.

[![ImMenu](https://img.shields.io/badge/Download-Menu.lua_lnx00-blue?style=for-the-badge&logo=github)](https://github.com/lnx00/Lmaobox-ImMenu/blob/main/src/ImMenu.lua) and copy the `imMenu.lua` file to your `%localappdata%` folder.

Python 3 is optional, but recommended if you want the local bridge middleware.


## Download
[![Download Latest](https://img.shields.io/github/downloads/titaniummachine1/Cheater_Priority/total.svg?style=for-the-badge&logo=download&label=Download%20Latest)](https://github.com/titaniummachine1/Cheater_Detection/releases/latest/download/Cheater_Detection.lua)

![image](https://github.com/titaniummachine1/Cheater_Detection/assets/78664175/bc8ea7b4-1313-46c2-a3a3-87b71ce0116b)

## Optional Local Bridge

Cheater Detection now ships with an optional localhost HTTP bridge in the `LocalBridge` folder.

When the bridge is running:

- online requests are submitted through the localhost promise-style bridge instead of blocking gameplay
- the Python bridge performs the real web request on a background thread
- Lua polls for the result and keeps using the bridge while it remains healthy

When the bridge is not running:

- the script still works normally
- blocking `http.Get` is only used during unobtrusive moments such as the main menu, loading screens, or when the local player is dead
- bridge health is only probed during those unobtrusive windows and is refreshed every 10 seconds

## Running The Bridge

1. Open `LocalBridge/StartLocalBridge.bat`.
2. Keep the terminal window open while you use the script.
3. Load Cheater Detection.

The script now shows a short startup prompt for the bridge. It disappears after 5 seconds or when you click anywhere.

## Project Layout

- `Cheater_Detection/services/http_queue.lua` owns the HTTP transport selection and fallback behavior.
- `LocalBridge/local_http_bridge_server.py` is the optional localhost bridge server.
- `LocalBridge/StartLocalBridge.bat` is the easiest way to launch it on Windows.


