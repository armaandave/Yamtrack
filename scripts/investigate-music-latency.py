"""Time the provider calls used by one cold music search and detail load."""

# ruff: noqa: INP001, T201

import argparse
import os
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

import django
import requests
from requests_ratelimiter import LimiterSession

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

django.setup()

from app.providers import musicbrainz, services  # noqa: E402


class MemoryCache:
    """Keep provider cache behavior within this single diagnostic run."""

    def __init__(self):
        """Initialize an empty cache."""
        self.data = {}

    def get(self, key, default=None):
        """Return a cached value."""
        return self.data.get(key, default)

    def set(self, key, value, _timeout=None):
        """Store a cached value."""
        self.data[key] = value


def main():
    """Run one cold search and detail trace."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--query", default="Year Zero Nine Inch Nails")
    parser.add_argument(
        "--release-group",
        default="3bd76d40-7f0e-36b7-9348-91a33afee20e",
    )
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--staged", action="store_true")
    args = parser.parse_args()

    musicbrainz.cache = MemoryCache()
    services.musicbrainz_session = LimiterSession(
        per_second=1,
        limit_statuses=(requests.codes.service_unavailable,),
    )
    services.session = LimiterSession(per_second=5)

    phase = "setup"
    calls = []
    api_request = services.api_request

    def timed_request(provider, method, url, **kwargs):
        started = time.monotonic()
        kwargs["timeout"] = min(kwargs.get("timeout") or args.timeout, args.timeout)
        try:
            return api_request(provider, method, url, **kwargs)
        finally:
            parsed = urlsplit(url)
            calls.append(
                (
                    phase,
                    provider,
                    method,
                    f"{parsed.netloc}{parsed.path}",
                    time.monotonic() - started,
                ),
            )

    services.api_request = timed_request

    def run(name, action):
        nonlocal phase
        phase = name
        started = time.monotonic()
        try:
            action()
        except Exception as error:  # noqa: BLE001 - retain later diagnostic phases.
            print(f"{name}: {type(error).__name__}: {error}")
        elapsed = time.monotonic() - started
        print(f"{name}_total: {elapsed:.3f}s")
        return elapsed

    run("search", lambda: musicbrainz.search(args.query, 1))
    if args.staged:
        basic = run(
            "basic_detail",
            lambda: musicbrainz.music(args.release_group, include_enrichment=False),
        )
        enrichment = run("enrichment", lambda: musicbrainz.music(args.release_group))
        print(f"staged_detail_total: {basic + enrichment:.3f}s")
    else:
        run("detail", lambda: musicbrainz.music(args.release_group))

    print("\nphase   seconds  provider           request")
    for call_phase, provider, method, url, elapsed in calls:
        print(f"{call_phase:<7} {elapsed:>7.3f}  {provider:<18} {method} {url}")


if __name__ == "__main__":
    main()
