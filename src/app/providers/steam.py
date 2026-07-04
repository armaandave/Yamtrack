import logging

import requests
from django.core.cache import cache

from app.providers import igdb, services

logger = logging.getLogger(__name__)
BASE_URL = "https://store.steampowered.com/api"


def get_metacritic_rating(igdb_media_id):
    """Return Steam's Metacritic payload for an IGDB game, when available."""
    missing = object()
    cache_key = f"steam_metacritic_igdb_{igdb_media_id}"
    cached = cache.get(cache_key, missing)
    if cached is not missing:
        return cached

    steam_id = _steam_app_id(igdb_media_id)
    rating = _metacritic_for_steam_app(steam_id) if steam_id else None
    cache.set(cache_key, rating, 86400)
    return rating


def _steam_app_id(igdb_media_id):
    try:
        return igdb.steam_app_id(igdb_media_id)
    except (requests.exceptions.RequestException, services.ProviderAPIError) as error:
        logger.warning("Steam app ID lookup failed for IGDB game %s: %s", igdb_media_id, error)
    return None


def _metacritic_for_steam_app(steam_id):
    try:
        response = services.api_request(
            "steam",
            "GET",
            f"{BASE_URL}/appdetails",
            params={"appids": steam_id, "filters": "metacritic"},
        )
    except requests.exceptions.RequestException as error:
        logger.warning("Steam Metacritic request failed for app %s: %s", steam_id, error)
        return None

    data = (response.get(str(steam_id)) or {}).get("data") or {}
    metacritic = data.get("metacritic") or {}
    score = metacritic.get("score")
    if score is None:
        return None
    return {
        "value": score,
        "url": metacritic.get("url"),
    }
