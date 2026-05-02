#!/usr/bin/env python3
"""Tiny local HTTP promise bridge.

Protocol:
- GET /health
- GET /submit?url=<encoded_url>&timeout_ms=<int>&max_bytes=<int>
- GET /result?id=<request_id>

Lua talks only to localhost. The bridge performs the real remote request on a
background thread and Lua polls until the job is done.
"""

from __future__ import annotations

import json
import threading
import time
import uuid
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen


HOST = "127.0.0.1"
PORT = 17354
PROTOCOL = "local-http-bridge-v1"
DEFAULT_TIMEOUT_MS = 10000
DEFAULT_MAX_BYTES = 2 * 1024 * 1024
MAX_TIMEOUT_MS = 120000
MAX_MAX_BYTES = 16 * 1024 * 1024
MAX_JOB_AGE_SEC = 300

Payload = dict[str, object]


@dataclass
class Job:
    created_at: float
    done: bool
    success: bool | None
    data: str | None
    error: str | None


JOBS: dict[str, Job] = {}
JOBS_LOCK = threading.Lock()


def clamp_int(raw_value: str | None, default: int, minimum: int, maximum: int) -> int:
    if raw_value is None:
        return default
    try:
        value = int(raw_value)
    except ValueError:
        return default
    if value < minimum:
        return minimum
    if value > maximum:
        return maximum
    return value


def first_value(query: dict[str, list[str]], key: str) -> str | None:
    values = query.get(key)
    if not values:
        return None
    return values[0]


def send_json(handler: BaseHTTPRequestHandler, payload: Payload, status_code: int = 200) -> None:
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    handler.send_response(status_code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


def send_text(handler: BaseHTTPRequestHandler, text: str, status_code: int = 200) -> None:
    body = text.encode("utf-8", errors="replace")
    handler.send_response(status_code)
    handler.send_header("Content-Type", "text/plain; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


def fetch_url(url: str, timeout_ms: int, max_bytes: int) -> tuple[bool, str | None, str | None]:
    timeout_seconds = timeout_ms / 1000.0
    request = Request(url, headers={"User-Agent": "LocalLuaBridge/1.0"})
    try:
        with urlopen(request, timeout=timeout_seconds) as response:
            raw = response.read(max_bytes + 1)
    except Exception as exc:  # noqa: BLE001
        return False, None, str(exc)

    if len(raw) > max_bytes:
        return False, None, f"response exceeds max_bytes={max_bytes}"

    return True, raw.decode("utf-8", errors="replace"), None


def finish_job(job_id: str, success: bool, data: str | None, error: str | None) -> None:
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if job is None:
            return
        job.done = True
        job.success = success
        job.data = data
        job.error = error


def run_job(job_id: str, url: str, timeout_ms: int, max_bytes: int) -> None:
    success, data, error = fetch_url(url, timeout_ms, max_bytes)
    finish_job(job_id, success, data, error)


def create_job(url: str, timeout_ms: int, max_bytes: int) -> str:
    job_id = str(uuid.uuid4())
    with JOBS_LOCK:
        JOBS[job_id] = Job(created_at=time.time(), done=False, success=None, data=None, error=None)
    thread = threading.Thread(target=run_job, args=(job_id, url, timeout_ms, max_bytes), daemon=True)
    thread.start()
    return job_id


def cleanup_jobs() -> None:
    now = time.time()
    stale_ids: list[str] = []
    with JOBS_LOCK:
        for job_id, job in JOBS.items():
            if now - job.created_at > MAX_JOB_AGE_SEC:
                stale_ids.append(job_id)
        for job_id in stale_ids:
            JOBS.pop(job_id, None)


def read_job(job_id: str) -> Job | None:
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if job is None:
            return None
        return Job(
            created_at=job.created_at,
            done=job.done,
            success=job.success,
            data=job.data,
            error=job.error,
        )


class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "LocalLuaBridge/1.0"

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        print(f"[bridge] {self.address_string()} - {format % args}")

    def do_GET(self) -> None:  # noqa: N802
        cleanup_jobs()

        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)

        if parsed.path == "/health_txt":
            send_text(self, f"ok|{PROTOCOL}\n")
            return

        if parsed.path == "/submit_txt":
            url = first_value(query, "url")
            if not url:
                send_text(self, "err|missing url\n", 400)
                return

            timeout_ms = clamp_int(first_value(query, "timeout_ms"), DEFAULT_TIMEOUT_MS, 100, MAX_TIMEOUT_MS)
            max_bytes = clamp_int(first_value(query, "max_bytes"), DEFAULT_MAX_BYTES, 1024, MAX_MAX_BYTES)
            job_id = create_job(url, timeout_ms, max_bytes)
            send_text(self, f"ok|{job_id}\n")
            return

        if parsed.path == "/result_txt":
            job_id = first_value(query, "id")
            if not job_id:
                send_text(self, "err|missing id\n", 400)
                return

            job = read_job(job_id)
            if job is None:
                send_text(self, "err|unknown id\n", 404)
                return

            if not job.done:
                send_text(self, "pending\n")
                return

            if job.success and job.data is not None:
                send_text(self, f"ok|{len(job.data)}\n{job.data}")
                return

            send_text(self, f"err|{job.error or 'remote request failed'}\n")
            return

        if parsed.path == "/health":
            send_json(self, {"ok": True, "alive": True, "protocol": PROTOCOL, "error": None})
            return

        if parsed.path == "/submit":
            url = first_value(query, "url")
            if not url:
                send_json(self, {"ok": False, "error": "missing url"}, 400)
                return

            timeout_ms = clamp_int(first_value(query, "timeout_ms"), DEFAULT_TIMEOUT_MS, 100, MAX_TIMEOUT_MS)
            max_bytes = clamp_int(first_value(query, "max_bytes"), DEFAULT_MAX_BYTES, 1024, MAX_MAX_BYTES)
            job_id = create_job(url, timeout_ms, max_bytes)
            send_json(self, {"ok": True, "id": job_id, "done": False, "error": None})
            return

        if parsed.path == "/result":
            job_id = first_value(query, "id")
            if not job_id:
                send_json(self, {"ok": False, "error": "missing id"}, 400)
                return

            job = read_job(job_id)
            if job is None:
                send_json(self, {"ok": False, "error": "unknown id", "id": job_id}, 404)
                return

            if not job.done:
                send_json(self, {"ok": True, "id": job_id, "done": False, "success": None, "data": None, "error": None})
                return

            send_json(
                self,
                {
                    "ok": True,
                    "id": job_id,
                    "done": True,
                    "success": job.success,
                    "data": job.data if job.success else None,
                    "error": job.error,
                },
            )
            return

        send_json(self, {"ok": False, "error": "not found"}, 404)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), BridgeHandler)
    print(f"[bridge] listening on http://{HOST}:{PORT}")
    print("[bridge] endpoints: /health /submit /result /health_txt /submit_txt /result_txt")
    server.serve_forever()


if __name__ == "__main__":
    main()