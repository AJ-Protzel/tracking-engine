"""Shared HTTP behaviour for every connector.

One request per second across the entire ingest run. Nobody is going to
complain about the volume this generates, but these are free endpoints run as a
courtesy and there is no reason to be the traffic that gets them locked down.
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Any

import httpx
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

log = logging.getLogger(__name__)

TIMEOUT = httpx.Timeout(10.0)
USER_AGENT = "tracking-engine/0.1 (+https://github.com/AJ-Protzel/tracking-engine)"
_MIN_INTERVAL = 1.0


class SourceUnavailable(Exception):
    """The endpoint failed in a way worth retrying."""


class BoardNotFound(Exception):
    """404 on a company slug.

    Not an error in any meaningful sense -- the slug is wrong, or the company
    moved off that ATS. The caller increments `fail_count` and moves on.
    """


class _RateLimiter:
    def __init__(self, min_interval: float) -> None:
        self._min_interval = min_interval
        self._lock = threading.Lock()
        self._last = 0.0

    def wait(self) -> None:
        with self._lock:
            elapsed = time.monotonic() - self._last
            if elapsed < self._min_interval:
                time.sleep(self._min_interval - elapsed)
            self._last = time.monotonic()


_limiter = _RateLimiter(_MIN_INTERVAL)


@retry(
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=2, max=10),
    retry=retry_if_exception_type(SourceUnavailable),
    reraise=True,
)
def get_json(url: str, *, params: dict[str, Any] | None = None,
             headers: dict[str, str] | None = None) -> Any:
    """GET and parse JSON, with backoff on transient failures.

    A 404 raises `BoardNotFound` and is never retried -- retrying a wrong slug
    three times just wastes the rate-limit budget.
    """
    _limiter.wait()
    merged = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    merged.update(headers or {})

    try:
        response = httpx.get(url, params=params, headers=merged,
                             timeout=TIMEOUT, follow_redirects=True)
    except httpx.RequestError as exc:
        raise SourceUnavailable(f"{url}: {exc}") from exc

    if response.status_code == 404:
        raise BoardNotFound(url)
    if response.status_code >= 500 or response.status_code == 429:
        raise SourceUnavailable(f"{url}: HTTP {response.status_code}")
    if response.status_code >= 400:
        raise BoardNotFound(f"{url}: HTTP {response.status_code}")

    try:
        return response.json()
    except ValueError as exc:
        raise SourceUnavailable(f"{url}: response was not JSON") from exc
