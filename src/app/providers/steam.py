import logging
from decimal import Decimal, ROUND_HALF_UP

import requests
from django.core.cache import cache

from app.providers import igdb, services

logger = logging.getLogger(__name__)
STORE_URL = "https://store.steampowered.com"
BASE_URL = f"{STORE_URL}/api"
CACHE_TIMEOUT = 86400
FAILURE_CACHE_TIMEOUT = 300
_FAILURE_MARKER = {"_failed": True}


def get_metacritic_rating(igdb_media_id, *, raise_errors=False):
    """Return Steam's Metacritic payload for an IGDB game, when available."""
    missing = object()
    cache_key = f"steam_metacritic_igdb_{igdb_media_id}"
    cached = cache.get(cache_key, missing)
    if cached is not missing:
        if cached == _FAILURE_MARKER:
            if raise_errors:
                msg = "Cached Steam Metacritic lookup failure"
                raise RuntimeError(msg)
            return None
        return cached

    try:
        steam_id = igdb.steam_app_id(igdb_media_id)
        rating = _metacritic_for_steam_app(steam_id) if steam_id else None
    except (requests.exceptions.RequestException, services.ProviderAPIError):
        logger.exception("Steam Metacritic lookup failed for IGDB game %s", igdb_media_id)
        if raise_errors:
            raise
        cache.set(cache_key, _FAILURE_MARKER, FAILURE_CACHE_TIMEOUT)
        return None

    cache.set(cache_key, rating, CACHE_TIMEOUT)
    return rating


def _metacritic_for_steam_app(steam_id):
    response = services.api_request(
        "steam",
        "GET",
        f"{BASE_URL}/appdetails",
        params={"appids": steam_id, "filters": "metacritic"},
    )

    data = (response.get(str(steam_id)) or {}).get("data") or {}
    metacritic = data.get("metacritic") or {}
    score = metacritic.get("score")
    if score is None:
        return None
    return {
        "value": score,
        "url": metacritic.get("url"),
    }


def get_review_rating(igdb_media_id, *, raise_errors=False):
    """Return Steam's lifetime user-review percentage for an IGDB game."""
    missing = object()
    cache_key = f"steam_reviews_igdb_{igdb_media_id}"
    cached = cache.get(cache_key, missing)
    if cached is not missing:
        if cached == _FAILURE_MARKER:
            if raise_errors:
                msg = "Cached Steam review lookup failure"
                raise RuntimeError(msg)
            return None
        return cached

    try:
        steam_id = igdb.steam_app_id(igdb_media_id)
        rating = _review_rating_for_steam_app(steam_id) if steam_id else None
    except (
        ValueError,
        requests.exceptions.RequestException,
        services.ProviderAPIError,
    ):
        logger.exception("Steam review lookup failed for IGDB game %s", igdb_media_id)
        cache.set(cache_key, _FAILURE_MARKER, FAILURE_CACHE_TIMEOUT)
        if raise_errors:
            raise
        return None

    cache.set(cache_key, rating, CACHE_TIMEOUT)
    return rating


def _review_rating_for_steam_app(steam_id):
    response = services.api_request(
        "steam",
        "GET",
        f"{STORE_URL}/appreviews/{steam_id}",
        params={
            "json": 1,
            "filter": "all",
            "language": "all",
            "day_range": 365,
            "review_type": "all",
            "purchase_type": "steam",
            "num_per_page": 1,
        },
    )
    if response.get("success") != 1:
        return None

    summary = response.get("query_summary")
    if not isinstance(summary, dict):
        msg = "Malformed Steam review summary"
        raise ValueError(msg)
    total = summary.get("total_reviews")
    positive = summary.get("total_positive")
    negative = summary.get("total_negative")
    if (
        type(total) is not int
        or type(positive) is not int
        or type(negative) is not int
        or total < 0
        or positive < 0
        or negative < 0
        or positive + negative != total
    ):
        msg = "Malformed Steam review counts"
        raise ValueError(msg)
    if total == 0:
        return None

    percentage = (Decimal(positive) * 100 / Decimal(total)).quantize(
        Decimal("1"),
        rounding=ROUND_HALF_UP,
    )
    return {
        "value": percentage,
        "vote_count": total,
        "url": f"{STORE_URL}/app/{steam_id}/",
    }
