import asyncio
import logging
import re

import aiohttp
import requests
from django.conf import settings
from django.core.cache import cache

from app import helpers
from app.models import MediaTypes, Sources
from app.providers import services
from app.providers.search_rank import rank_results

logger = logging.getLogger(__name__)

base_url = "https://api.mangaupdates.com/v1"


def handle_error(error):
    """Handle MangaUpdates API errors."""
    error_resp = error.response
    status_code = error_resp.status_code

    try:
        error_json = error_resp.json()
    except requests.exceptions.JSONDecodeError as json_error:
        logger.exception("Failed to decode JSON response")
        raise services.ProviderAPIError(
            Sources.MANGAUPDATES.value,
            error,
        ) from json_error

    if status_code == requests.codes.bad_request:
        search_error = error_json["context"].get("search")
        if search_error:
            message = search_error[0]["errors"][0]
            if message == '"" must have a length between 1 and 400':
                return {"results": [], "total_hits": 0}

    raise services.ProviderAPIError(
        Sources.MANGAUPDATES.value,
        error,
    )


def search(query, page, *, preserve_ranking_fields=False, timeout=None):
    """Search for media on MangaUpdates."""
    rank_suffix = "_rank" if preserve_ranking_fields else ""
    cache_key = (
        f"search_{Sources.MANGAUPDATES.value}_{MediaTypes.MANGA.value}_{query}_{page}{rank_suffix}"
    )
    data = cache.get(cache_key)

    if data is None:
        url = f"{base_url}/series/search"
        per_page = 30
        params = {
            "search": query,
            "stype": "title",
            "perpage": per_page,
            "page": page,
        }

        if not settings.MAL_NSFW:
            params["exclude_genre"] = [
                "Adult",
                "Hentai",
                "Doujinshi",
            ]

        try:
            response = services.api_request(
                Sources.MANGAUPDATES.value,
                "POST",
                url,
                params=params,
                timeout=timeout,
            )
        except requests.exceptions.HTTPError as error:
            response = handle_error(error)

        results = [
            {
                "media_id": media["record"]["series_id"],
                "source": Sources.MANGAUPDATES.value,
                "media_type": MediaTypes.MANGA.value,
                "title": media["record"]["title"],
                "image": get_image_url(media["record"]),
            }
            for media in response["results"]
        ]
        results = rank_results(
            query,
            results,
            MediaTypes.MANGA.value,
            preserve_ranking_fields=preserve_ranking_fields,
        )

        total_results = response["total_hits"]
        data = helpers.format_search_response(
            page,
            per_page,
            total_results,
            results,
        )

        cache.set(cache_key, data)

    return data


def search_people(query, *, limit=10, timeout=None):
    """Search MangaUpdates authors and return normalized person references."""
    try:
        response = services.api_request(
            Sources.MANGAUPDATES.value,
            "POST",
            f"{base_url}/authors/search",
            params={
                "search": query,
                "page": 1,
                "perpage": limit,
            },
            timeout=timeout,
            retry_rate_limits=False,
            request_session=services.person_search_session,
        )
    except requests.exceptions.HTTPError as error:
        response = handle_error(error)

    results = []
    for hit in response.get("results") or []:
        author = hit.get("record") or hit
        person_id = author.get("author_id") or author.get("id")
        if person_id is None or not author.get("name"):
            continue
        image = author.get("image") or {}
        image_urls = image.get("url") if isinstance(image, dict) else {}
        results.append({
            "source": Sources.MANGAUPDATES.value,
            "person_id": str(person_id),
            "name": author["name"],
            "profile_url": (
                image_urls.get("original")
                or image_urls.get("thumb")
                or None
                if isinstance(image_urls, dict)
                else None
            ),
            "known_for_department": author.get("type") or "Author",
        })
    return results[:limit]


def manga(media_id):
    """Get metadata for a manga from MangaUpdates."""
    return asyncio.run(async_manga(media_id))


async def async_manga(media_id):
    """Asynchronous implementation of manga metadata retrieval."""
    cache_key = f"{Sources.MANGAUPDATES.value}_{MediaTypes.MANGA.value}_{media_id}_v2"
    data = cache.get(cache_key)

    if data is None:
        url = f"{base_url}/series/{media_id}"

        try:
            response = services.api_request(Sources.MANGAUPDATES.value, "GET", url)
        except requests.exceptions.HTTPError as error:
            handle_error(error)

        # Run related_manga and recommendations concurrently
        related_task = asyncio.create_task(
            get_related_series(response["related_series"]),
        )
        recommendations_task = asyncio.create_task(
            get_recommendations(response["recommendations"]),
        )

        data = {
            "media_id": media_id,
            "source": Sources.MANGAUPDATES.value,
            "source_url": response["url"],
            "media_type": MediaTypes.MANGA.value,
            "title": response["title"],
            "image": get_image_url(response),
            "posters": [
                {
                    "url": get_image_url(response),
                    "thumbnail_url": get_image_url(response),
                    "provider_name": "MangaUpdates",
                    "provider_url": response["url"],
                    "is_original": True,
                },
            ],
            "synopsis": response["description"],
            "max_progress": get_max_progress(response),
            "genres": get_genres(response["genres"]),
            "score": get_score(response["bayesian_rating"]),
            "score_count": response["rating_votes"],
            "creators": get_creators(response.get("authors")),
            "details": {
                "format": response["type"],
                "authors": get_authors(response["authors"]),
                "alternative_titles": get_associated_titles(response),
                "year": response["year"],
                "status_in_country_of_origin": get_status(response["status"]),
                "latest_chapter_translated": response["latest_chapter"],
            },
            "related": {
                "relations": await related_task,
                "recommendations": await recommendations_task,
            },
        }

        cache.set(cache_key, data)

    return data


def get_image_url(response):
    """Get the image URL for a media item."""
    # when no image, value from response is null
    url = response["image"]["url"]["original"]
    return url or settings.IMG_NONE


def get_max_progress(response):
    """Get the maximum progress if the media is completed."""
    if response["completed"]:
        return response["latest_chapter"]
    return None


def get_genres(genres):
    """Return the genres for the media."""
    if genres:
        return [item["genre"] for item in genres]
    return None


def get_authors(authors):
    """Get the authors for a media item."""
    if authors:
        return [item["name"] for item in authors]
    return None


def get_creators(authors):
    """Return MangaUpdates creators using the shared credit shape."""
    creators = []
    seen = set()
    for author in authors or []:
        name = str(author.get("name") or "").strip()
        role = str(author.get("type") or author.get("role") or "").strip()
        key = (name.casefold(), role.casefold())
        if not name or key in seen:
            continue
        seen.add(key)
        person_id = author.get("author_id")
        creators.append({
            "person_id": str(person_id or ""),
            **(
                {"person_source": Sources.MANGAUPDATES.value}
                if person_id
                else {}
            ),
            "name": name,
            "role": role or None,
        })
    return creators[:12]


def person_page(person_id):
    """Return a MangaUpdates author profile and manga bibliography."""
    cache_key = f"{Sources.MANGAUPDATES.value}_person_{person_id}_v1"
    data = cache.get(cache_key)
    if data is not None:
        return data

    try:
        author = services.api_request(
            Sources.MANGAUPDATES.value,
            "GET",
            f"{base_url}/authors/{person_id}",
        )
        bibliography = services.api_request(
            Sources.MANGAUPDATES.value,
            "POST",
            f"{base_url}/authors/{person_id}/series",
            params={"page": 1, "perpage": 500},
        )
    except requests.exceptions.HTTPError as error:
        handle_error(error)

    if not author or not author.get("id"):
        services.raise_not_found_error(
            Sources.MANGAUPDATES.value,
            person_id,
            "person",
        )

    credits = []
    for series in bibliography.get("series_list") or []:
        series_id = series.get("series_id")
        if not series_id:
            continue
        year = series.get("year")
        credits.append({
            "media_type": MediaTypes.MANGA.value,
            "source": Sources.MANGAUPDATES.value,
            "media_id": str(series_id),
            "title": series.get("title") or "",
            "year": str(year) if year else None,
            "release_date": str(year) if year else None,
            "genres": series.get("genres") or [],
            "roles": ["Author"],
            "credit_roles": ["Author"],
            "url": series.get("url"),
        })

    image = ((author.get("image") or {}).get("url") or {})
    birthday = author.get("birthday") or {}
    data = {
        "source": Sources.MANGAUPDATES.value,
        "person_id": str(author.get("id") or person_id),
        "name": author.get("name") or "",
        "image": image.get("original") or image.get("thumb"),
        "biography": helpers.plain_text(author.get("comments")),
        "known_for_department": "Author",
        "birth_date": _author_date(birthday),
        "death_date": (
            _author_date(author.get("status_date") or {})
            if str(author.get("status") or "").casefold() == "deceased"
            else None
        ),
        "place_of_birth": author.get("birthplace"),
        "popularity": (author.get("stats") or {}).get("total_series"),
        "credits": credits,
    }
    cache.set(cache_key, data)
    return data


def _author_date(value):
    year = value.get("year")
    if not year:
        return None
    month = value.get("month")
    day = value.get("day")
    if month and day:
        return f"{year:04d}-{month:02d}-{day:02d}"
    if month:
        return f"{year:04d}-{month:02d}"
    return str(year)


def get_associated_titles(response):
    """Return title aliases from the MangaUpdates series response."""
    values = response.get("associated") or response.get("associated_titles") or []
    titles = []
    seen = set()
    for value in values:
        if isinstance(value, dict):
            value = value.get("title") or value.get("name")
        title = str(value or "").strip()
        key = title.casefold()
        if title and key not in seen:
            seen.add(key)
            titles.append(title)
    return titles


def get_status(status):
    """Return the status of the media."""
    # can be null 67117539345
    # e.g berserk 51239621230 needs parsing
    if status:
        pattern = r"(\d+\s+Volumes\s+\([^)]+\))"
        match = re.search(pattern, status)
        if match:
            return match.group(1)
    return status


def get_score(score):
    """Return the score for the media."""
    # can be null 29732162445
    if score:
        return round(score, 1)
    return None


async def get_related_series(related):
    """Return list of related media for the selected media asynchronously."""
    async with aiohttp.ClientSession() as session:
        tasks = [
            fetch_series_data(
                session,
                f"{base_url}/series/{item['related_series_id']}",
                item,
            )
            for item in related
            if item["related_series_name"]
        ]
        results = await asyncio.gather(*tasks)
    return [item for item in results if item is not None]


async def get_recommendations(recommendations):
    """Return list of recommended media for the selected media asynchronously."""
    async with aiohttp.ClientSession() as session:
        tasks = [
            fetch_series_data(session, f"{base_url}/series/{item['series_id']}", item)
            for item in recommendations
            if item["series_name"]
        ]
        results = await asyncio.gather(*tasks)
    return [item for item in results if item is not None]


async def fetch_series_data(session, url, item):
    """Fetch series data asynchronously."""
    async with session.get(url) as response:
        if response.status == requests.codes.ok:
            data = await response.json()
            image = get_image_url(data)
            return {
                "source": Sources.MANGAUPDATES.value,
                "media_id": item.get("related_series_id") or item.get("series_id"),
                "media_type": MediaTypes.MANGA.value,
                "title": item.get("related_series_name") or item.get("series_name"),
                "image": image,
                **(
                    {"relation": relation}
                    if (
                        relation := _relation_label(
                            item.get("relation_type")
                            or item.get("relation")
                            or item.get("type"),
                        )
                    )
                    else {}
                ),
            }
    return None


def _relation_label(value):
    label = str(value or "").replace("_", " ").strip()
    return label.title() if label else "Related"
