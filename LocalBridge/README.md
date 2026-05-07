# Local Bridge

Run `StartLocalBridge.bat` to launch the optional localhost HTTP bridge used by Cheater Detection.

When the bridge is running, the Lua queue submits remote requests to `http://127.0.0.1:17354`, the Python server performs the real web request on a background thread, and Lua polls for the result.

Bridge behavior:
- Uses a worker pool (`20` workers) with a priority queue instead of creating an unbounded thread per request.
- Prioritizes request keys that have gone the longest without being served.
- Deduplicates identical in-flight requests (`url + timeout + max_bytes`) so duplicate polls do not fan out into duplicate upstream HTTP calls.
- Caches recent responses for a short TTL (endpoint-aware) to reduce repeated requests and rate-limit pressure.
- Supports optional batch endpoints for future use:
	- `GET /submit_batch?url=<...>&url=<...>`
	- `GET /result_batch?id=<...>&id=<...>`

When the bridge is not running, Cheater Detection still works, but blocking HTTP is only attempted during safe moments such as the main menu, loading screens, or when the local player is dead.