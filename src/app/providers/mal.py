import logging
import re
import time
import unicodedata
from datetime import datetime
from zoneinfo import ZoneInfo

import requests
from django.conf import settings
from django.core.cache import cache

from app import helpers
from app.models import MediaTypes, Sources
from app.providers import services
from app.providers.search_rank import rank_results

logger = logging.getLogger(__name__)
base_url = "https://api.myanimelist.net/v2"
jikan_base_url = "https://api.jikan.moe/v4"
base_fields = "title,alternative_titles,main_picture,pictures,media_type,start_date,end_date,synopsis,status,genres,mean,num_scoring_users,recommendations"  # noqa: E501
MANGA_MATCH_VERSION = "v1"
MANGA_MATCH_FRESH_TTL = 60 * 60 * 24
MANGA_MATCH_STALE_TTL = 60 * 60 * 24 * 30
MANGA_MATCH_FAILURE_TTL = 60 * 5
PERSON_TTL = 60 * 60 * 24
ANIME_CAST_CACHE_VERSION = "v1"
ANIME_CAST_FRESH_TTL = 60 * 60 * 24
ANIME_CAST_STALE_TTL = 60 * 60 * 24 * 30
ANIME_CAST_FAILURE_TTL = 60 * 5


def handle_error(error):
    """Handle MAL API errors."""
    error_resp = error.response
    status_code = error_resp.status_code

    try:
        error_json = error_resp.json()
    except requests.exceptions.JSONDecodeError as json_error:
        logger.exception("Failed to decode JSON response")
        raise services.ProviderAPIError(Sources.MAL.value, error) from json_error

    if status_code == requests.codes.forbidden:
        details = "API key is missing"
        raise services.ProviderAPIError(Sources.MAL.value, error, details)
    if status_code == requests.codes.bad_request:
        error_message = error_json.get("message")
        if error_message == "Invalid client id":
            details = "Invalid API key"
            raise services.ProviderAPIError(Sources.MAL.value, error, details)
        if error_message == "invalid q":
            return {"data": []}

    raise services.ProviderAPIError(Sources.MAL.value, error)


def search(media_type, query, page, *, preserve_ranking_fields=False, timeout=None):
    """Search for media on MyAnimeList."""
    rank_suffix = "_rank" if preserve_ranking_fields else ""
    cache_key = f"search_{Sources.MAL.value}_{media_type}_{query}_{page}{rank_suffix}"
    data = cache.get(cache_key)

    if data is None:
        url = f"{base_url}/{media_type}"
        params = {
            "q": query,
            "fields": "media_type,mean,num_scoring_users,start_date",
            "limit": settings.PER_PAGE,
        }
        if settings.MAL_NSFW:
            params["nsfw"] = "true"

        try:
            response = services.api_request(
                Sources.MAL.value,
                "GET",
                url,
                params=params,
                headers={"X-MAL-CLIENT-ID": settings.MAL_API},
                timeout=timeout,
            )
        except requests.exceptions.HTTPError as error:
            response = handle_error(error)

        response = response["data"]
        results = [
            {
                "media_id": media["node"]["id"],
                "source": Sources.MAL.value,
                "media_type": media_type,
                "title": media["node"]["title"],
                "image": get_image_url(media["node"]),
                "rating": media["node"].get("mean"),
                "num_scoring_users": media["node"].get("num_scoring_users"),
                "release_date": media["node"].get("start_date"),
            }
            for media in response
        ]
        results = rank_results(
            query,
            results,
            media_type,
            preserve_ranking_fields=preserve_ranking_fields,
        )

        data = helpers.format_search_response(
            page,
            100,
            len(results),
            results,
        )

        cache.set(cache_key, data)

    return data


def anime(media_id):
    """Return the metadata for the selected anime or manga from MyAnimeList."""
    cache_key = f"{Sources.MAL.value}_{MediaTypes.ANIME.value}_{media_id}_v2"
    data = cache.get(cache_key)

    if data is None:
        url = f"{base_url}/anime/{media_id}"
        params = {
            "fields": f"{base_fields},num_episodes,average_episode_duration,studios,start_season,broadcast,source,related_anime",  # noqa: E501
        }

        try:
            response = services.api_request(
                Sources.MAL.value,
                "GET",
                url,
                params=params,
                headers={"X-MAL-CLIENT-ID": settings.MAL_API},
            )
        except requests.exceptions.HTTPError as error:
            handle_error(error)

        num_episodes = get_number_of_episodes(response)

        data = {
            "media_id": media_id,
            "source": Sources.MAL.value,
            "source_url": f"https://myanimelist.net/anime/{media_id}",
            "media_type": MediaTypes.ANIME.value,
            "title": response["title"],
            "display_title": get_english_title(response),
            "max_progress": num_episodes,
            "image": get_image_url(response),
            "posters": get_pictures(response, media_id, MediaTypes.ANIME.value),
            "synopsis": get_synopsis(response),
            "genres": get_genres(response),
            "score": get_score(response),
            "score_count": get_score_count(response),
            "details": {
                "format": get_format(response),
                "start_date": response.get("start_date"),
                "end_date": response.get("end_date"),
                "status": get_readable_status(response),
                "episodes": num_episodes,
                "runtime": get_runtime(response),
                "studios": get_studios(response),
                "season": get_season(response),
                "broadcast": get_broadcast(response),
                "source": get_source(response),
            },
            "related": {
                "relations": get_related(
                    response.get("related_anime"),
                    MediaTypes.ANIME.value,
                ),
                "recommendations": get_related(
                    response.get("recommendations"),
                    MediaTypes.ANIME.value,
                ),
            },
        }

        cache.set(cache_key, data)

    return data


def manga(media_id):
    """Return the metadata for the selected anime or manga from MyAnimeList."""
    cache_key = f"{Sources.MAL.value}_{MediaTypes.MANGA.value}_{media_id}_v3"
    data = cache.get(cache_key)

    if data is None:
        url = f"{base_url}/manga/{media_id}"
        params = {
            "fields": (
                f"{base_fields},num_chapters,num_volumes,authors,serialization,"
                "related_anime,related_manga,recommendations"
            ),
        }

        try:
            response = services.api_request(
                Sources.MAL.value,
                "GET",
                url,
                params=params,
                headers={"X-MAL-CLIENT-ID": settings.MAL_API},
            )
        except requests.exceptions.HTTPError as error:
            handle_error(error)

        num_chapters = get_number_of_episodes(response)

        data = {
            "media_id": media_id,
            "source": Sources.MAL.value,
            "source_url": f"https://myanimelist.net/manga/{media_id}",
            "media_type": MediaTypes.MANGA.value,
            "title": response["title"],
            "display_title": get_english_title(response),
            "image": get_image_url(response),
            "posters": get_pictures(response, media_id, MediaTypes.MANGA.value),
            "synopsis": get_synopsis(response),
            "max_progress": num_chapters,
            "genres": get_genres(response),
            "score": get_score(response),
            "score_count": get_score_count(response),
            "creators": get_authors(response),
            "details": {
                "format": get_format(response),
                "start_date": response.get("start_date"),
                "end_date": response.get("end_date"),
                "status": get_readable_status(response),
                "number_of_chapters": num_chapters,
                "number_of_volumes": response.get("num_volumes") or None,
                "authors": [creator["name"] for creator in get_authors(response)],
                "serialization": [
                    item["node"]["name"]
                    for item in response.get("serialization") or []
                    if isinstance(item, dict) and (item.get("node") or {}).get("name")
                ],
            },
            "related": {
                "relations": [
                    *get_related(
                        response.get("related_manga"),
                        MediaTypes.MANGA.value,
                    ),
                    *get_related(
                        response.get("related_anime"),
                        MediaTypes.ANIME.value,
                    ),
                ],
                "recommendations": get_related(
                    response.get("recommendations"),
                    MediaTypes.MANGA.value,
                ),
            },
        }

        cache.set(cache_key, data)

    return data


def match_manga(mangaupdates_id, metadata, *, timeout=3):
    """Return a strictly matched MAL manga ID for MangaUpdates metadata."""
    fresh_key, stale_key, failure_key = _manga_match_keys(mangaupdates_id)
    cached = cache.get(fresh_key)
    if cached is not None:
        return cached.get("mal_id")

    stale = cache.get(stale_key)
    if cache.get(failure_key):
        return stale.get("mal_id") if stale else None

    details = metadata.get("details") or {}
    titles = _match_titles(
        metadata.get("title"),
        details.get("alternative_titles"),
    )
    if not titles:
        cache.set(fresh_key, {"mal_id": None}, MANGA_MATCH_FRESH_TTL)
        return None

    expected_year = _year(details.get("year") or details.get("start_date"))
    expected_format = _format_family(details.get("format"))
    deadline = time.monotonic() + timeout
    candidates = {}

    try:
        for query in titles[:4]:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            response = services.api_request(
                Sources.MAL.value,
                "GET",
                f"{base_url}/manga",
                params={
                    "q": query,
                    "fields": "alternative_titles,media_type,start_date",
                    "limit": 10,
                    **({"nsfw": "true"} if settings.MAL_NSFW else {}),
                },
                headers={"X-MAL-CLIENT-ID": settings.MAL_API},
                timeout=remaining,
            )
            for result in response.get("data") or []:
                node = result.get("node") or {}
                node_titles = _match_titles(
                    node.get("title"),
                    (node.get("alternative_titles") or {}).values(),
                )
                if not set(titles).intersection(node_titles):
                    continue
                node_year = _year(node.get("start_date"))
                node_format = _format_family(node.get("media_type"))
                if (
                    expected_year
                    and node_year
                    and expected_year != node_year
                ) or (
                    expected_format
                    and node_format
                    and expected_format != node_format
                ):
                    continue
                if node.get("id") is not None:
                    candidates[str(node["id"])] = node
    except (
        requests.RequestException,
        services.ProviderAPIError,
        AttributeError,
        TypeError,
        ValueError,
    ) as error:
        logger.warning(
            "MAL manga match unavailable for MangaUpdates %s: %s",
            mangaupdates_id,
            error,
        )
        cache.set(failure_key, True, MANGA_MATCH_FAILURE_TTL)
        return stale.get("mal_id") if stale else None

    match = next(iter(candidates)) if len(candidates) == 1 else None
    payload = {"mal_id": match}
    cache.set(fresh_key, payload, MANGA_MATCH_FRESH_TTL)
    if match:
        cache.set(stale_key, payload, MANGA_MATCH_STALE_TTL)
    cache.delete(failure_key)
    return match


def cached_manga_match(mangaupdates_id):
    """Return a cached positive MangaUpdates-to-MAL match."""
    fresh_key, stale_key, _failure_key = _manga_match_keys(mangaupdates_id)
    payload = cache.get(fresh_key)
    if payload is None:
        payload = cache.get(stale_key)
    return payload.get("mal_id") if payload else None


def _manga_match_keys(mangaupdates_id):
    prefix = f"mal:{MANGA_MATCH_VERSION}:manga-match:{mangaupdates_id}"
    return f"{prefix}:fresh", f"{prefix}:stale", f"{prefix}:failure"


def get_format(response):
    """Return the original type of the media."""
    media_format = response["media_type"]

    # MAL return tv in metadata for anime
    if media_format == "tv":
        return "Anime"
    if media_format in ("ova", "ona"):
        return media_format.upper()
    return media_format.replace("_", " ").title()


def get_image_url(response):
    """Return the image URL for the media."""
    # when no picture, main_picture is not present in the response
    # e.g anime: 38869
    try:
        return response["main_picture"]["large"]
    except KeyError:
        return settings.IMG_NONE


def get_english_title(response):
    """Return MAL's English title without changing the canonical title."""
    value = (response.get("alternative_titles") or {}).get("en")
    return value.strip() if isinstance(value, str) and value.strip() else None


def get_pictures(response, media_id, media_type):
    """Return deduplicated MAL poster candidates."""
    source_url = f"https://myanimelist.net/{media_type}/{media_id}"
    pictures = [response.get("main_picture"), *(response.get("pictures") or [])]
    results = []
    seen = set()
    for index, picture in enumerate(pictures):
        if not isinstance(picture, dict):
            continue
        url = picture.get("large") or picture.get("medium")
        if not url or url in seen:
            continue
        seen.add(url)
        results.append(
            {
                "url": url,
                "thumbnail_url": picture.get("medium") or url,
                "provider_name": "MyAnimeList",
                "provider_url": source_url,
                "is_original": index == 0,
            },
        )
    return results


def get_authors(response):
    """Return MAL manga creators with their credited roles."""
    creators = []
    seen = set()
    for author in response.get("authors") or []:
        node = author.get("node") or {}
        name = str(node.get("first_name") or "").strip()
        last_name = str(node.get("last_name") or "").strip()
        full_name = " ".join(part for part in (name, last_name) if part)
        full_name = full_name or str(node.get("name") or "").strip()
        role = str(author.get("role") or "").replace("_", " ").strip().title()
        key = (full_name.casefold(), role.casefold())
        if not full_name or key in seen:
            continue
        seen.add(key)
        person_id = node.get("id")
        creators.append({
            "person_id": str(person_id or ""),
            **({"person_source": Sources.MAL.value} if person_id else {}),
            "name": full_name,
            "role": role or None,
        })
    return creators[:12]


def anime_cast(media_id, *, raise_errors=False):
    """Return cached Jikan voice cast when AniList enrichment is unavailable."""
    prefix = f"mal:{ANIME_CAST_CACHE_VERSION}:anime-cast:{media_id}"
    fresh_key = f"{prefix}:fresh"
    stale_key = f"{prefix}:stale"
    failure_key = f"{prefix}:failure"
    if data := cache.get(fresh_key):
        return data

    stale = cache.get(stale_key)
    if cache.get(failure_key):
        if stale:
            return stale
        if raise_errors:
            raise RuntimeError("Cached Jikan anime cast failure")
        return []

    try:
        response = services.api_request(
            Sources.MAL.value,
            "GET",
            f"{jikan_base_url}/anime/{media_id}/characters",
            timeout=3,
        )
        cast = _normalize_jikan_anime_cast(response.get("data") or [])
        cache.set(fresh_key, cast, ANIME_CAST_FRESH_TTL)
        cache.set(stale_key, cast, ANIME_CAST_STALE_TTL)
        cache.delete(failure_key)
        return cast
    except (
        requests.RequestException,
        AttributeError,
        KeyError,
        TypeError,
        ValueError,
    ):
        logger.warning("Jikan cast unavailable for MAL anime %s", media_id)
        cache.set(failure_key, True, ANIME_CAST_FAILURE_TTL)
        if stale:
            return stale
        if raise_errors:
            raise
        return []


def _normalize_jikan_anime_cast(entries):
    cast = []
    positions = {}
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        character = entry.get("character") or {}
        character_name = str(character.get("name") or "").strip()
        voice_actors = entry.get("voice_actors") or []
        voice_actor = next(
            (
                actor
                for actor in voice_actors
                if str(actor.get("language") or "").casefold() == "japanese"
            ),
            voice_actors[0] if voice_actors else None,
        )
        person = (voice_actor or {}).get("person") or {}
        person_id = person.get("mal_id")
        name = str(person.get("name") or "").strip()
        if not person_id or not name or not character_name:
            continue
        key = str(person_id)
        if key in positions:
            current = cast[positions[key]]
            characters = current["character"].split(" · ")
            if character_name not in characters:
                current["character"] = " · ".join([*characters, character_name])
            continue
        images = person.get("images") or {}
        image = images.get("jpg") or images.get("webp") or {}
        positions[key] = len(cast)
        cast.append({
            "person_id": key,
            "person_source": Sources.MAL.value,
            "name": name,
            "character": character_name,
            "image": image.get("image_url") or image.get("large_image_url"),
        })
    return cast


def person_page(person_id, *, timeout=None, retry_rate_limits=True):
    """Return MAL person data through Jikan, which exposes MAL's people pages."""
    cache_key = f"{Sources.MAL.value}_person_{person_id}_v2"
    data = cache.get(cache_key)
    if data is not None:
        return data

    try:
        response = services.api_request(
            Sources.MAL.value,
            "GET",
            f"{jikan_base_url}/people/{person_id}/full",
            timeout=timeout,
            retry_rate_limits=retry_rate_limits,
        )
    except requests.exceptions.HTTPError as error:
        handle_error(error)

    person = response.get("data") or {}
    if not person:
        services.raise_not_found_error(Sources.MAL.value, person_id, "person")

    credits = []
    positions = {}
    for entry in person.get("manga") or []:
        manga_data = entry.get("manga") or {}
        role = str(entry.get("position") or "").strip() or "Author"
        _merge_jikan_person_credit(
            credits,
            positions,
            manga_data,
            media_type=MediaTypes.MANGA.value,
            role=role,
        )
    for entry in person.get("anime") or []:
        _merge_jikan_person_credit(
            credits,
            positions,
            entry.get("anime") or {},
            media_type=MediaTypes.ANIME.value,
            role=str(entry.get("position") or "").strip() or "Staff",
        )
    for entry in person.get("voices") or []:
        _merge_jikan_person_credit(
            credits,
            positions,
            entry.get("anime") or {},
            media_type=MediaTypes.ANIME.value,
            role="Voice Actor",
        )

    profile_images = person.get("images") or {}
    profile_image = profile_images.get("jpg") or profile_images.get("webp") or {}
    data = {
        "source": Sources.MAL.value,
        "person_id": str(person.get("mal_id") or person_id),
        "name": person.get("name") or "",
        "alternative_names": _jikan_person_alternative_names(person),
        "image": profile_image.get("image_url") or profile_image.get("large_image_url"),
        "biography": helpers.plain_text(person.get("about")),
        "known_for_department": _jikan_known_for_department(credits),
        "birth_date": person.get("birthday"),
        "death_date": None,
        "place_of_birth": None,
        "popularity": person.get("favorites"),
        "credits": credits,
    }
    cache.set(cache_key, data, PERSON_TTL)
    return data


def person_page_by_name(name, alternative_names=None, birth_date=None, *, timeout=1):
    """Find the matching MAL person and return their full Jikan profile."""
    if not str(name or "").strip():
        return None
    response = services.api_request(
        Sources.MAL.value,
        "GET",
        f"{jikan_base_url}/people",
        params={
            "q": name,
            "limit": 10,
            "order_by": "favorites",
            "sort": "desc",
        },
        timeout=timeout,
        retry_rate_limits=False,
    )
    target_names = _person_name_keys([name, *(alternative_names or [])])
    candidates = [
        candidate
        for candidate in response.get("data") or []
        if target_names
        & _person_name_keys(
            [
                candidate.get("name"),
                candidate.get("given_name"),
                candidate.get("family_name"),
                *(candidate.get("alternate_names") or []),
            ],
        )
    ]
    if not candidates:
        return None
    birthday = str(birth_date or "")[:10]
    match = max(
        candidates,
        key=lambda candidate: (
            bool(birthday and str(candidate.get("birthday") or "")[:10] == birthday),
            candidate.get("favorites") or 0,
        ),
    )
    person_id = match.get("mal_id")
    return (
        person_page(
            person_id,
            timeout=timeout,
            retry_rate_limits=False,
        )
        if person_id
        else None
    )


def _person_name_keys(values):
    keys = set()
    for value in values:
        normalized = _normalize_match_title(value)
        if not normalized:
            continue
        keys.add(normalized)
        words = normalized.split()
        if len(words) > 1 and all(word.isascii() for word in words):
            keys.add(" ".join(sorted(words)))
    return keys


def _merge_jikan_person_credit(
    credits,
    positions,
    media,
    *,
    media_type,
    role,
):
    media_id = media.get("mal_id")
    if not media_id:
        return
    key = (media_type, str(media_id))
    if key in positions:
        current = credits[positions[key]]
        if role not in current["credit_roles"]:
            current["roles"].append(role)
            current["credit_roles"].append(role)
        return

    images = media.get("images") or {}
    image = images.get("jpg") or images.get("webp") or {}
    positions[key] = len(credits)
    credits.append({
        "media_type": media_type,
        "source": Sources.MAL.value,
        "media_id": str(media_id),
        "title": media.get("title_english") or media.get("title") or "",
        "display_title": media.get("title_english") or media.get("title") or "",
        "image": image.get("large_image_url") or image.get("image_url"),
        "roles": [role],
        "credit_roles": [role],
        "url": media.get("url")
        or f"https://myanimelist.net/{media_type}/{media_id}",
    })


def _jikan_person_alternative_names(person):
    values = [
        person.get("given_name"),
        person.get("family_name"),
        *(person.get("alternate_names") or []),
    ]
    primary = str(person.get("name") or "").strip().casefold()
    seen = {primary} if primary else set()
    results = []
    for value in values:
        clean = str(value or "").strip()
        if clean and clean.casefold() not in seen:
            seen.add(clean.casefold())
            results.append(clean)
    return results


def _jikan_known_for_department(credits):
    roles = [
        role
        for credit in credits
        for role in credit.get("credit_roles") or []
    ]
    if "Voice Actor" in roles:
        return "Voice Actor"
    return roles[0] if roles else None


def _match_titles(primary, alternatives=None):
    values = [primary]
    pending = (
        list(alternatives.values())
        if isinstance(alternatives, dict)
        else list(alternatives or [])
    )
    while pending:
        value = pending.pop(0)
        if isinstance(value, (list, tuple, set)):
            pending[:0] = value
        else:
            values.append(value)
    results = []
    seen = set()
    for value in values:
        normalized = _normalize_match_title(value)
        if normalized and normalized not in seen:
            seen.add(normalized)
            results.append(normalized)
    return results


def _normalize_match_title(value):
    text = unicodedata.normalize("NFKC", str(value or "")).casefold()
    return re.sub(r"[\W_]+", " ", text, flags=re.UNICODE).strip()


def _year(value):
    match = re.search(r"\b(\d{4})\b", str(value or ""))
    return int(match.group(1)) if match else None


def _format_family(value):
    normalized = str(value or "").casefold().replace("_", " ").strip()
    if not normalized:
        return None
    if "novel" in normalized:
        return "novel"
    if "one shot" in normalized or "oneshot" in normalized:
        return "one-shot"
    if any(
        label in normalized
        for label in ("manga", "manhwa", "manhua", "doujin", "oel", "webtoon", "comic")
    ):
        return "comic"
    return None


def get_readable_status(response):
    """Return the status in human-readable format."""
    # Map status to human-readable values
    status_map = {
        "finished_airing": "Finished",
        "currently_airing": "Airing",
        "not_yet_aired": "Upcoming",
        "finished": "Finished",
        "currently_publishing": "Publishing",
        "not_yet_published": "Upcoming",
        "on_hiatus": "On Hiatus",
        "discontinued": "Discontinued",
    }
    if response["status"] in status_map:
        return status_map[response["status"]]
    return response["status"].replace("_", " ").title()


def get_synopsis(response):
    """Add the synopsis to the response."""
    # when no synopsis, value from response is empty string
    # e.g manga: 160219
    if response["synopsis"] == "":
        return "No synopsis available."
    return response["synopsis"]


def get_number_of_episodes(response):
    """Return the number of episodes for the media."""
    # when unknown episodes, value from response is 0
    # e.g manga: 160219
    try:
        episodes = response["num_episodes"]
    except KeyError:
        episodes = response["num_chapters"]

    return episodes if episodes != 0 else None


def get_runtime(response):
    """Return the average episode duration."""
    # when unknown duration, value from response is 0
    # e.g anime: 43333
    duration = response["average_episode_duration"]

    # Convert average_episode_duration to hours and minutes
    if duration:
        # duration are in seconds
        hours, minutes = divmod(int(duration / 60), 60)
        return f"{hours}h {minutes}m" if hours > 0 else f"{minutes} min"
    return None


def get_genres(response):
    """Return the genres for the media."""
    # when unknown genres, genres key is not present in the response
    # e.g manga: 151971
    if response.get("genres"):
        return [genre["name"] for genre in response["genres"]]
    return None


def get_studios(response):
    """Return the studios for the media."""
    # when unknown studio, studios is an empty list
    # e.g anime: 43333

    if response["studios"]:
        return [studio["name"] for studio in response["studios"]]
    return None


def get_season(response):
    """Return the season for the media."""
    # when unknown start season, no start_season key in response
    # e.g anime: 43333
    try:
        season = response["start_season"]
        return f"{season['season'].title()} {season['year']}"
    except KeyError:
        return None


def get_broadcast(response):
    """Return the broadcast day and time for the media."""
    start_date = response.get("start_date")
    if not start_date:
        return None

    # when unknown broadcast, value is not present in the response
    # e.g anime: 38869
    broadcast = response.get("broadcast")
    if not broadcast:
        return None

    # when unknown start time, value is not present in the broadcast dict
    start_time = broadcast.get("start_time") if broadcast else None
    if not start_time:
        return None

    japan_timezone = ZoneInfo("Asia/Tokyo")
    # Try parsing with different date formats
    try:
        date_obj = datetime.strptime(start_date, "%Y-%m-%d").replace(
            tzinfo=japan_timezone,
        )
    except ValueError:
        date_obj = datetime.strptime(start_date, "%Y-%m").replace(tzinfo=japan_timezone)

    broadcast_time_japan = datetime.strptime(
        f"{date_obj.strftime('%Y-%m-%d')} {start_time}",
        "%Y-%m-%d %H:%M",
    ).replace(tzinfo=japan_timezone)

    broadcast_time_local = broadcast_time_japan.astimezone(settings.TZ)
    return broadcast_time_local.strftime("%A %H:%M")


def get_source(response):
    """Return the source for the media."""
    # when unknown source, value from response is empty string
    # e.g anime: 32253
    try:
        return response["source"].replace("_", " ").title()
    except KeyError:
        return None


def get_score(response):
    """Return the score for the media."""
    # when num_scoring_users is small, the response does not include this field.
    try:
        return round(response["mean"], 1)
    except KeyError:
        return None


def get_score_count(response):
    """Return the score count for the media."""
    if get_score(response):
        return response["num_scoring_users"]
    return 0


def get_related(related_medias, media_type):
    """Return list of related media for the selected media."""
    if related_medias:
        return [
            {
                "media_id": media["node"]["id"],
                "source": Sources.MAL.value,
                "title": media["node"]["title"],
                "media_type": media_type,
                "image": get_image_url(media["node"]),
                **(
                    {"relation": media["relation_type_formatted"]}
                    if media.get("relation_type_formatted")
                    else {}
                ),
            }
            for media in related_medias
        ]
    return []
