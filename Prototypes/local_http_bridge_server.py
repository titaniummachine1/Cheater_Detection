#!/usr/bin/env python3
"""
Local HTTP bridge for Lmaobox testing.

Goal:
- Lua uses blocking http.Get against localhost only (very fast).
- The bridge performs real remote HTTP in background worker threads.
- Lua polls for completion and receives success/data or failure/error.

Endpoints:
- GET /health
- GET /submit?url=<encoded_url>&timeout_ms=<int>&max_bytes=<int>
- GET /result?id=<request_id>
- GET /fetch_sync?url=<encoded_url>&timeout_ms=<int>&max_bytes=<int> (debug only)

Response shape (JSON):
{
  "ok": true|false,
  "done": true|false,
  "success": true|false|null,
  "data": string|null,
  "error": string|null,
  "id": string|null
}
"""

from __future__ import annotations

import json
import threading
import time
import uuid
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, Optional
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen


HOST = "127.0.0.1"
PORT = 17354
DEFAULT_TIMEOUT_MS = 10000
DEFAULT_MAX_BYTES = 2 * 1024 * 1024
MAX_TIMEOUT_MS = 120000
MAX_RESULT_AGE_SEC = 300


@dataclass
class Job:
    created_at: float
    done: bool
    success: Optional[bool]
    data: Optional[str]
    error: Optional[str]


_jobs: Dict[str, Job] = {}
_jobs_lock = threading.Lock()


def _clamp_int(value: Optional[str], default: int, low: int, high: int) -> int:
    if value is None:
        return default
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    if parsed < low:
        return low
    if parsed > high:
        return high
    return parsed


def _fetch_url(url: str, timeout_ms: int, max_bytes: int) -> tuple[bool, Optional[str], Optional[str]]:
    timeout_sec = timeout_ms / 1000.0
    try:
        req = Request(url, headers={"User-Agent": "LocalLuaBridge/1.0"})
        with urlopen(req, timeout=timeout_sec) as response:
            raw = response.read(max_bytes + 1)
            if len(raw) > max_bytes:
                return False, None, f"response exceeds max_bytes={max_bytes}"
            text = raw.decode("utf-8", errors="replace")
            return True, text, None
    except Exception as exc:  # noqa: BLE001 - explicit bridge error capture
        return False, None, str(exc)


def _worker(job_id: str, url: str, timeout_ms: int, max_bytes: int) -> None:
    success, data, error = _fetch_url(url, timeout_ms, max_bytes)
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job is None:
            return
        job.done = True
        job.success = success
        job.data = data
        job.error = error


def _cleanup_old_jobs(now: float) -> None:
    stale_ids = []
    with _jobs_lock:
        for job_id, job in _jobs.items():
            if now - job.created_at > MAX_RESULT_AGE_SEC:
                stale_ids.append(job_id)
        for job_id in stale_ids:
            _jobs.pop(job_id, None)


class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "LocalLuaBridge/1.0"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        # Keep output concise and useful for testing.
        print(f"[bridge] {self.address_string()} - {fmt % args}")

    def _write_json(self, payload: dict, status_code: int = 200) -> None:
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        now = time.time()
        _cleanup_old_jobs(now)

        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)

        if parsed.path == "/health":
            self._write_json({"ok": True, "done": True, "success": True, "data": "ok", "error": None, "id": None})
            return

        if parsed.path == "/submit":
            url = (query.get("url") or [None])[0]
            if not url:
                self._write_json(
                    {"ok": False, "done": True, "success": False, "data": None, "error": "missing url", "id": None},
                    status_code=400,
                )
                return

            timeout_ms = _clamp_int((query.get("timeout_ms") or [None])[0], DEFAULT_TIMEOUT_MS, 100, MAX_TIMEOUT_MS)
            max_bytes = _clamp_int((query.get("max_bytes") or [None])[0], DEFAULT_MAX_BYTES, 1024, 16 * 1024 * 1024)

            job_id = str(uuid.uuid4())
            with _jobs_lock:
                _jobs[job_id] = Job(created_at=now, done=False, success=None, data=None, error=None)

            thread = threading.Thread(target=_worker, args=(job_id, url, timeout_ms, max_bytes), daemon=True)
            thread.start()

            self._write_json({"ok": True, "done": False, "success": None, "data": None, "error": None, "id": job_id})
            return

        if parsed.path == "/result":
            job_id = (query.get("id") or [None])[0]
            if not job_id:
                self._write_json(
                    {"ok": False, "done": True, "success": False, "data": None, "error": "missing id", "id": None},
                    status_code=400,
                )
                return

            with _jobs_lock:
                job = _jobs.get(job_id)

            if job is None:
                self._write_json(
                    {"ok": False, "done": True, "success": False, "data": None, "error": "unknown id", "id": job_id},
                    status_code=404,
                )
                return

            self._write_json(
                {
                    "ok": True,
                    "done": job.done,
                    "success": job.success,
                    "data": job.data if job.done and job.success else None,
                    "error": job.error,
                    "id": job_id,
                }
            )
            return

        if parsed.path == "/fetch_sync":
            url = (query.get("url") or [None])[0]
            if not url:
                self._write_json(
                    {"ok": False, "done": True, "success": False, "data": None, "error": "missing url", "id": None},
                    status_code=400,
                )
                return

            timeout_ms = _clamp_int((query.get("timeout_ms") or [None])[0], DEFAULT_TIMEOUT_MS, 100, MAX_TIMEOUT_MS)
            max_bytes = _clamp_int((query.get("max_bytes") or [None])[0], DEFAULT_MAX_BYTES, 1024, 16 * 1024 * 1024)
            success, data, error = _fetch_url(url, timeout_ms, max_bytes)
            self._write_json(
                {
                    "ok": True,
                    "done": True,
                    "success": success,
                    "data": data if success else None,
                    "error": error,
                    "id": None,
                }
            )
            return

        self._write_json(
            {"ok": False, "done": True, "success": False, "data": None, "error": "not found", "id": None},
            status_code=404,
        )


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), BridgeHandler)
    print(f"[bridge] listening on http://{HOST}:{PORT}")
    print("[bridge] endpoints: /health /submit /result /fetch_sync")
    server.serve_forever()


if __name__ == "__main__":
    main()
