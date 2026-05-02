# Local Bridge

Run `StartLocalBridge.bat` to launch the optional localhost HTTP bridge used by Cheater Detection.

When the bridge is running, the Lua queue submits remote requests to `http://127.0.0.1:17354`, the Python server performs the real web request on a background thread, and Lua polls for the result.

When the bridge is not running, Cheater Detection still works, but blocking HTTP is only attempted during safe moments such as the main menu, loading screens, or when the local player is dead.