"""Licensed IMDb rating lookups through AWS Data Exchange."""

import json
import logging
import re

from django.conf import settings
from django.core.cache import cache

logger = logging.getLogger(__name__)

CACHE_VERSION = 1
CACHE_TIMEOUT = 60 * 60 * 24
FAILURE_CACHE_TIMEOUT = 60 * 5
IMDB_ID_PATTERN = re.compile(r"tt\d+")
_FAILURE_MARKER = {"_failed": True}


def is_configured():
    """Return whether all IMDb Data Exchange asset settings are available."""
    return all(
        (
            settings.IMDB_API_KEY,
            settings.IMDB_DATA_SET_ID,
            settings.IMDB_REVISION_ID,
            settings.IMDB_ASSET_ID,
        ),
    )


def get_title_rating(imdb_id, *, raise_errors=False):
    """Return the current IMDb rating for a title ID, or ``None`` when unavailable."""
    if not is_configured() or not IMDB_ID_PATTERN.fullmatch(str(imdb_id or "")):
        return None

    imdb_id = str(imdb_id)
    cache_key = f"imdb_rating_v{CACHE_VERSION}_{imdb_id}"
    uncached = object()
    cached = cache.get(cache_key, uncached)
    if cached is not uncached:
        if cached == _FAILURE_MARKER:
            if raise_errors:
                msg = "Cached IMDb rating lookup failure"
                raise RuntimeError(msg)
            return None
        return cached or None

    try:
        response = _client().send_api_asset(
            DataSetId=settings.IMDB_DATA_SET_ID,
            RevisionId=settings.IMDB_REVISION_ID,
            AssetId=settings.IMDB_ASSET_ID,
            Method="POST",
            Path="/v1",
            Body=json.dumps(
                {
                    "query": (
                        f'query {{ title(id: "{imdb_id}") '
                        "{ ratingsSummary { aggregateRating voteCount } } }"
                    ),
                },
            ),
            RequestHeaders={"x-api-key": settings.IMDB_API_KEY},
        )
        payload = _response_payload(response)
        summary = ((payload.get("data") or {}).get("title") or {}).get(
            "ratingsSummary",
        ) or {}
        value = summary.get("aggregateRating")
        if value is None:
            cache.set(cache_key, {}, timeout=CACHE_TIMEOUT)
            return None

        rating = {
            "value": value,
            "votes": summary.get("voteCount"),
            "url": f"https://www.imdb.com/title/{imdb_id}/",
        }
        cache.set(cache_key, rating, timeout=CACHE_TIMEOUT)
        return rating
    except Exception:
        # The media page remains useful with its link-only IMDb pill when the
        # optional licensed service is unavailable or temporarily misconfigured.
        logger.exception("IMDb rating lookup failed for title %s", imdb_id)
        if raise_errors:
            raise
        cache.set(cache_key, _FAILURE_MARKER, timeout=FAILURE_CACHE_TIMEOUT)
        return None


def _client():
    """Create the official AWS Data Exchange client through boto3's credential chain."""
    import boto3

    return boto3.client("dataexchange", region_name=settings.IMDB_AWS_REGION)


def _response_payload(response):
    """Decode the JSON GraphQL body returned by ``send_api_asset``."""
    body = response.get("Body") or "{}"
    if isinstance(body, bytes):
        body = body.decode("utf-8")
    payload = json.loads(body)
    if payload.get("errors"):
        msg = "IMDb API returned GraphQL errors"
        raise ValueError(msg)
    return payload
