#!/usr/bin/env python3
"""Tiny local HTTP promise bridge.

Protocol:
- GET /health
- GET /submit?url=<encoded_url>&timeout_ms=<int>&max_bytes=<int>
- GET /submit_json?url=<encoded_url>&method=<HTTP_METHOD>&content_type=<mime>&body=<encoded_body>&timeout_ms=<int>&max_bytes=<int>
- GET /result?id=<request_id>

Optional batch helpers:
- GET /submit_batch?url=<encoded_url>&url=<encoded_url2>...
- GET /result_batch?id=<request_id>&id=<request_id2>...

Lua talks only to localhost. The bridge performs remote requests using a
priority worker queue, deduplicates identical in-flight requests, and keeps a
short-lived response cache to reduce upstream request pressure.
"""

from __future__ import annotations

import heapq
import itertools
import json
import threading
import time
import uuid
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen


HOST = "127.0.0.1"
PORT = 17354
PROTOCOL = "local-http-bridge-v2"
DEFAULT_TIMEOUT_MS = 10000
DEFAULT_MAX_BYTES = 2 * 1024 * 1024
MAX_TIMEOUT_MS = 120000
MAX_MAX_BYTES = 16 * 1024 * 1024
MAX_JOB_AGE_SEC = 300
MAX_PENDING_JOBS = 20000
WORKER_COUNT = 20
MAX_CACHE_ENTRIES = 5000

Payload = dict[str, object]


@dataclass
class Job:
    created_at: float
    updated_at: float
    request_key: str
    url: str
    timeout_ms: int
    max_bytes: int
    method: str
    body: str
    content_type: str
    done: bool
    success: bool | None
    data: str | None
    error: str | None
    source_job_id: str | None
    worker_started: bool


@dataclass(order=True)
class QueueItem:
    priority: float
    sequence: int
    job_id: str = field(compare=False)


@dataclass
class CacheEntry:
    expires_at: float
    success: bool
    data: str | None
    error: str | None


JOBS: dict[str, Job] = {}
PENDING: list[QueueItem] = []
SUBSCRIBERS: dict[str, set[str]] = {}
INFLIGHT_BY_KEY: dict[str, str] = {}
LAST_SERVED_BY_KEY: dict[str, float] = {}
RESULT_CACHE: dict[str, CacheEntry] = {}
QUEUE_SEQUENCE = itertools.count()

JOBS_LOCK = threading.Lock()
JOBS_COND = threading.Condition(JOBS_LOCK)


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


def first_values(query: dict[str, list[str]], key: str) -> list[str]:
    values = query.get(key)
    if not values:
        return []
    return values


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


def cache_ttl_seconds(url: str, success: bool) -> int:
    lowered = url.lower()
    if "mac/game/v1" in lowered or "mac/user/v1" in lowered:
        ttl = 20
    elif "steamhistory" in lowered:
        ttl = 120
    elif "steam" in lowered:
        ttl = 45
    else:
        ttl = 10

    if not success:
        return min(ttl, 5)
    return ttl


def make_request_key(
    url: str,
    timeout_ms: int,
    max_bytes: int,
    method: str,
    body: str,
    content_type: str,
) -> str:
    return f"{timeout_ms}|{max_bytes}|{method}|{content_type}|{body}|{url}"


def fetch_url(
    url: str,
    timeout_ms: int,
    max_bytes: int,
    method: str,
    body: str,
    content_type: str,
) -> tuple[bool, str | None, str | None]:
    timeout_seconds = timeout_ms / 1000.0
    body_bytes = None
    if body:
        body_bytes = body.encode("utf-8", errors="replace")

    headers = {"User-Agent": "LocalLuaBridge/2.0"}
    if content_type:
        headers["Content-Type"] = content_type

    request = Request(url, data=body_bytes, headers=headers, method=method)
    try:
        with urlopen(request, timeout=timeout_seconds) as response:
            raw = response.read(max_bytes + 1)
    except Exception as exc:  # noqa: BLE001
        return False, None, str(exc)

    if len(raw) > max_bytes:
        return False, None, f"response exceeds max_bytes={max_bytes}"

    return True, raw.decode("utf-8", errors="replace"), None


def cleanup_state_locked(now: float) -> None:
    stale_job_ids: list[str] = []
    for job_id, job in JOBS.items():
        if job.done and now - job.created_at > MAX_JOB_AGE_SEC:
            stale_job_ids.append(job_id)

    for job_id in stale_job_ids:
        JOBS.pop(job_id, None)

    stale_keys: list[str] = []
    for key, entry in RESULT_CACHE.items():
        if now >= entry.expires_at:
            stale_keys.append(key)

    for key in stale_keys:
        RESULT_CACHE.pop(key, None)


def prune_cache_locked() -> None:
    if len(RESULT_CACHE) <= MAX_CACHE_ENTRIES:
        return

    keys_by_expiry = sorted(RESULT_CACHE.keys(), key=lambda key: RESULT_CACHE[key].expires_at)
    drop_count = len(RESULT_CACHE) - MAX_CACHE_ENTRIES
    for key in keys_by_expiry[:drop_count]:
        RESULT_CACHE.pop(key, None)


def finish_job_locked(job_id: str, success: bool, data: str | None, error: str | None) -> None:
    now = time.time()
    job = JOBS.get(job_id)
    if job is None:
        return

    job.done = True
    job.success = success
    job.data = data
    job.error = error
    job.updated_at = now

    LAST_SERVED_BY_KEY[job.request_key] = now

    ttl_seconds = cache_ttl_seconds(job.url, success)
    RESULT_CACHE[job.request_key] = CacheEntry(
        expires_at=now + ttl_seconds,
        success=success,
        data=data,
        error=error,
    )
    prune_cache_locked()

    inflight_job_id = INFLIGHT_BY_KEY.get(job.request_key)
    if inflight_job_id == job_id:
        INFLIGHT_BY_KEY.pop(job.request_key, None)

    subscriber_ids = SUBSCRIBERS.pop(job_id, set())
    for subscriber_id in subscriber_ids:
        subscriber = JOBS.get(subscriber_id)
        if subscriber is None or subscriber.done:
            continue
        subscriber.done = True
        subscriber.success = success
        subscriber.data = data
        subscriber.error = error
        subscriber.updated_at = now


def create_job(
    url: str,
    timeout_ms: int,
    max_bytes: int,
    method: str = "GET",
    body: str = "",
    content_type: str = "",
) -> str:
    request_key = make_request_key(url, timeout_ms, max_bytes, method, body, content_type)
    now = time.time()

    with JOBS_COND:
        cleanup_state_locked(now)

        cache_entry = RESULT_CACHE.get(request_key)
        if cache_entry is not None and now < cache_entry.expires_at:
            job_id = str(uuid.uuid4())
            JOBS[job_id] = Job(
                created_at=now,
                updated_at=now,
                request_key=request_key,
                url=url,
                timeout_ms=timeout_ms,
                max_bytes=max_bytes,
                method=method,
                body=body,
                content_type=content_type,
                done=True,
                success=cache_entry.success,
                data=cache_entry.data,
                error=cache_entry.error,
                source_job_id=None,
                worker_started=False,
            )
            return job_id

        in_flight = INFLIGHT_BY_KEY.get(request_key)
        if in_flight is not None:
            root_job = JOBS.get(in_flight)
            if root_job is not None and not root_job.done:
                job_id = str(uuid.uuid4())
                JOBS[job_id] = Job(
                    created_at=now,
                    updated_at=now,
                    request_key=request_key,
                    url=url,
                    timeout_ms=timeout_ms,
                    max_bytes=max_bytes,
                    method=method,
                    body=body,
                    content_type=content_type,
                    done=False,
                    success=None,
                    data=None,
                    error=None,
                    source_job_id=in_flight,
                    worker_started=False,
                )
                SUBSCRIBERS.setdefault(in_flight, set()).add(job_id)
                return job_id

        if len(PENDING) >= MAX_PENDING_JOBS:
            raise RuntimeError("bridge queue is full")

        job_id = str(uuid.uuid4())
        JOBS[job_id] = Job(
            created_at=now,
            updated_at=now,
            request_key=request_key,
            url=url,
            timeout_ms=timeout_ms,
            max_bytes=max_bytes,
            method=method,
            body=body,
            content_type=content_type,
            done=False,
            success=None,
            data=None,
            error=None,
            source_job_id=None,
            worker_started=False,
        )

        INFLIGHT_BY_KEY[request_key] = job_id
        SUBSCRIBERS.setdefault(job_id, set())

        # Oldest "not checked" request_key runs first.
        priority = LAST_SERVED_BY_KEY.get(request_key, 0.0)
        heapq.heappush(PENDING, QueueItem(priority=priority, sequence=next(QUEUE_SEQUENCE), job_id=job_id))
        JOBS_COND.notify()
        return job_id


def read_job(job_id: str) -> Job | None:
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if job is None:
            return None
        return Job(
            created_at=job.created_at,
            updated_at=job.updated_at,
            request_key=job.request_key,
            url=job.url,
            timeout_ms=job.timeout_ms,
            max_bytes=job.max_bytes,
            method=job.method,
            body=job.body,
            content_type=job.content_type,
            done=job.done,
            success=job.success,
            data=job.data,
            error=job.error,
            source_job_id=job.source_job_id,
            worker_started=job.worker_started,
        )


def worker_loop(worker_index: int) -> None:
    while True:
        job_id: str | None = None
        timeout_ms = DEFAULT_TIMEOUT_MS
        max_bytes = DEFAULT_MAX_BYTES
        url = ""
        method = "GET"
        body = ""
        content_type = ""

        with JOBS_COND:
            while True:
                cleanup_state_locked(time.time())
                if PENDING:
                    break
                JOBS_COND.wait(timeout=0.5)

            while PENDING:
                item = heapq.heappop(PENDING)
                candidate = JOBS.get(item.job_id)
                if candidate is None:
                    continue
                if candidate.done or candidate.worker_started:
                    continue

                candidate.worker_started = True
                candidate.updated_at = time.time()
                job_id = item.job_id
                url = candidate.url
                timeout_ms = candidate.timeout_ms
                max_bytes = candidate.max_bytes
                method = candidate.method
                body = candidate.body
                content_type = candidate.content_type
                break

            if job_id is None:
                continue

        success, data, error = fetch_url(url, timeout_ms, max_bytes, method, body, content_type)

        with JOBS_COND:
            finish_job_locked(job_id, success, data, error)
            JOBS_COND.notify_all()


class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "LocalLuaBridge/2.0"

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        print(f"[bridge] {self.address_string()} - {format % args}")

    def do_GET(self) -> None:  # noqa: N802
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

            try:
                job_id = create_job(url, timeout_ms, max_bytes)
            except RuntimeError as exc:
                send_text(self, f"err|{exc}\n", 503)
                return

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
            with JOBS_LOCK:
                pending = len(PENDING)
                in_flight = len(INFLIGHT_BY_KEY)
                cache_size = len(RESULT_CACHE)
            send_json(
                self,
                {
                    "ok": True,
                    "alive": True,
                    "protocol": PROTOCOL,
                    "workers": WORKER_COUNT,
                    "pending": pending,
                    "in_flight": in_flight,
                    "cache_entries": cache_size,
                    "error": None,
                },
            )
            return

        if parsed.path == "/submit":
            url = first_value(query, "url")
            if not url:
                send_json(self, {"ok": False, "error": "missing url"}, 400)
                return

            timeout_ms = clamp_int(first_value(query, "timeout_ms"), DEFAULT_TIMEOUT_MS, 100, MAX_TIMEOUT_MS)
            max_bytes = clamp_int(first_value(query, "max_bytes"), DEFAULT_MAX_BYTES, 1024, MAX_MAX_BYTES)

            try:
                job_id = create_job(url, timeout_ms, max_bytes)
            except RuntimeError as exc:
                send_json(self, {"ok": False, "error": str(exc)}, 503)
                return

            send_json(self, {"ok": True, "id": job_id, "done": False, "error": None})
            return

        if parsed.path == "/submit_json":
            url = first_value(query, "url")
            if not url:
                send_json(self, {"ok": False, "error": "missing url"}, 400)
                return

            method = (first_value(query, "method") or "POST").upper()
            if method == "":
                method = "POST"
            content_type = first_value(query, "content_type") or "application/json"
            body = first_value(query, "body") or ""

            timeout_ms = clamp_int(first_value(query, "timeout_ms"), DEFAULT_TIMEOUT_MS, 100, MAX_TIMEOUT_MS)
            max_bytes = clamp_int(first_value(query, "max_bytes"), DEFAULT_MAX_BYTES, 1024, MAX_MAX_BYTES)

            try:
                job_id = create_job(url, timeout_ms, max_bytes, method, body, content_type)
            except RuntimeError as exc:
                send_json(self, {"ok": False, "error": str(exc)}, 503)
                return

            send_json(self, {"ok": True, "id": job_id, "done": False, "error": None})
            return

        if parsed.path == "/submit_batch":
            urls = first_values(query, "url")
            if not urls:
                send_json(self, {"ok": False, "error": "missing url"}, 400)
                return

            timeout_ms = clamp_int(first_value(query, "timeout_ms"), DEFAULT_TIMEOUT_MS, 100, MAX_TIMEOUT_MS)
            max_bytes = clamp_int(first_value(query, "max_bytes"), DEFAULT_MAX_BYTES, 1024, MAX_MAX_BYTES)

            items: list[dict[str, object]] = []
            for url in urls:
                try:
                    job_id = create_job(url, timeout_ms, max_bytes)
                except RuntimeError as exc:
                    items.append({"ok": False, "url": url, "error": str(exc)})
                    continue
                items.append({"ok": True, "url": url, "id": job_id, "done": False, "error": None})

            send_json(self, {"ok": True, "items": items, "count": len(items)})
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

        if parsed.path == "/result_batch":
            ids = first_values(query, "id")
            if not ids:
                send_json(self, {"ok": False, "error": "missing id"}, 400)
                return

            items: list[dict[str, object]] = []
            for job_id in ids:
                job = read_job(job_id)
                if job is None:
                    items.append({"ok": False, "id": job_id, "error": "unknown id"})
                    continue
                if not job.done:
                    items.append({"ok": True, "id": job_id, "done": False, "success": None, "data": None, "error": None})
                    continue
                items.append(
                    {
                        "ok": True,
                        "id": job_id,
                        "done": True,
                        "success": job.success,
                        "data": job.data if job.success else None,
                        "error": job.error,
                    }
                )

            send_json(self, {"ok": True, "items": items, "count": len(items)})
            return

        send_json(self, {"ok": False, "error": "not found"}, 404)


def start_workers() -> None:
    for worker_index in range(WORKER_COUNT):
        thread = threading.Thread(target=worker_loop, args=(worker_index,), daemon=True)
        thread.start()


def main() -> None:
    start_workers()
    server = ThreadingHTTPServer((HOST, PORT), BridgeHandler)
    print(f"[bridge] listening on http://{HOST}:{PORT}")
    print(
        "[bridge] endpoints: /health /submit /submit_json /result /submit_batch /result_batch /health_txt /submit_txt /result_txt"
    )
    print(f"[bridge] workers={WORKER_COUNT} max_pending={MAX_PENDING_JOBS} max_cache_entries={MAX_CACHE_ENTRIES}")
    server.serve_forever()


if __name__ == "__main__":
    main()
