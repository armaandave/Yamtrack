import logging

import requests
from django.core.cache import cache

from app.providers import igdb, services

logger = logging.getLogger(__name__)
BASE_URL = "https://store.steampowered.com/api"
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
