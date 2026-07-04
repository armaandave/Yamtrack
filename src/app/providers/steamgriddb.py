import logging
from urllib.parse import quote

import requests
from django.conf import settings
from django.core.cache import cache
from django.utils.text import slugify

from app.providers import igdb, services

logger = logging.getLogger(__name__)

PROVIDER = "steamgriddb"
BASE_URL = "https://www.steamgriddb.com/api/v2"
CACHE_TTL = 60 * 60 * 24


def get_game_posters(media_id):
    """Return vertical SteamGridDB grids for an IGDB game."""
    return _cached_assets(
        "posters",
        media_id,
        "grids",
        {
            "dimensions": "600x900,660x930,342x482",
            "types": "static",
            "nsfw": "false",
            "humor": "false",
            "epilepsy": "false",
            "limit": 50,
        },
        fallback_aspect_ratio=0.667,
    )


def get_game_backdrops(media_id):
    """Return SteamGridDB hero images for an IGDB game."""
    return _cached_assets(
        "backdrops",
        media_id,
        "heroes",
        {
            "types": "static",
            "nsfw": "false",
            "humor": "false",
            "epilepsy": "false",
            "limit": 50,
        },
        fallback_aspect_ratio=3.097,
    )


def get_game_logo(media_id):
    """Return the best transparent SteamGridDB logo for an IGDB game."""
    logos = _cached_assets(
        "logos",
        media_id,
        "logos",
        {
            "styles": "official,custom,white,black",
            "types": "static",
            "mimes": "image/png,image/webp",
            "nsfw": "false",
            "humor": "false",
            "epilepsy": "false",
            "limit": 50,
        },
        fallback_aspect_ratio=None,
    )
    if not logos:
        return None
    style_rank = {"official": 0, "custom": 1, "white": 2, "black": 3}
    return sorted(
        logos,
        key=lambda logo: (
            style_rank.get(logo.get("style"), 99),
            -(logo.get("vote_count") or 0),
        ),
    )[0]


def _cached_assets(kind, media_id, endpoint, params, fallback_aspect_ratio):
    cache_key = f"{PROVIDER}_{kind}_{media_id}_v2"
    cached = cache.get(cache_key)
    if cached is not None:
        return cached

    steam_id = _steam_app_id(media_id)
    assets = []
    if steam_id:
        assets = _assets_for_path(
            f"{endpoint}/steam/{steam_id}",
            params=params,
            fallback_aspect_ratio=fallback_aspect_ratio,
        )

    if not assets:
        steamgriddb_game_id = _steamgriddb_game_id(media_id)
        if steamgriddb_game_id:
            assets = _assets_for_path(
                f"{endpoint}/game/{steamgriddb_game_id}",
                params=params,
                fallback_aspect_ratio=fallback_aspect_ratio,
            )

    cache.set(cache_key, assets, CACHE_TTL)
    return assets


def _assets_for_path(path, *, params, fallback_aspect_ratio):
    response = _get(path, params=params)
    if not response:
        return []
    assets = [
        _asset_option(asset, fallback_aspect_ratio=fallback_aspect_ratio)
        for asset in (response or {}).get("data", [])
        if asset.get("url")
    ]
    return assets


def _steam_app_id(media_id):
    try:
        return igdb.steam_app_id(media_id)
    except (requests.exceptions.RequestException, services.ProviderAPIError) as error:
        logger.warning("SteamGridDB Steam app ID lookup failed for IGDB game %s: %s", media_id, error)
    return None


def _steamgriddb_game_id(media_id):
    cache_key = f"{PROVIDER}_game_id_{media_id}_v1"
    missing = object()
    cached = cache.get(cache_key, missing)
    if cached is not missing:
        return cached

    title = _igdb_title(media_id)
    game_id = _search_game_id(title) if title else None
    cache.set(cache_key, game_id, CACHE_TTL)
    return game_id


def _igdb_title(media_id):
    try:
        return igdb.game(media_id).get("title")
    except (requests.exceptions.RequestException, services.ProviderAPIError) as error:
        logger.warning("SteamGridDB IGDB title lookup failed for game %s: %s", media_id, error)
    return None


def _search_game_id(title):
    response = _get(f"search/autocomplete/{quote(title, safe='')}")
    wanted = _normalize_title(title)
    for game in (response or {}).get("data", []):
        if _normalize_title(game.get("name")) == wanted:
            return game.get("id")
    return None


def _normalize_title(title):
    return slugify(title or "").casefold()


def _get(path, params=None):
    token = getattr(settings, "STEAMGRIDDB_API_KEY", "")
    if not token:
        return None
    try:
        return services.api_request(
            PROVIDER,
            "GET",
            f"{BASE_URL}/{path.lstrip('/')}",
            params=params,
            headers={
                "Authorization": f"Bearer {token}",
                "User-Agent": "Spine/1.0",
            },
        )
    except requests.exceptions.RequestException as error:
        logger.warning("SteamGridDB request failed: %s", error)
    return None


def _asset_option(asset, *, fallback_aspect_ratio):
    width = asset.get("width") or 0
    height = asset.get("height") or 0
    aspect_ratio = round(width / height, 3) if width and height else fallback_aspect_ratio
    return {
        "url": asset["url"],
        "thumbnail_url": asset.get("thumb") or asset["url"],
        "width": width,
        "height": height,
        "aspect_ratio": aspect_ratio,
        "vote_average": 0,
        "vote_count": asset.get("score") or 0,
        "language": None,
        "source": PROVIDER,
        "provider": "SteamGridDB",
        "asset_id": asset.get("id"),
        "style": asset.get("style"),
    }
