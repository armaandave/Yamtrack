import asyncio
import hashlib
import logging
from copy import deepcopy
from datetime import UTC, date, datetime
from decimal import Decimal, InvalidOperation
from urllib.parse import quote, urlencode, urljoin, urlsplit, urlunsplit

from aiohttp import ClientError
from django.conf import settings
from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.core.validators import URLValidator
from django.db.models import Count

from api.serializers.common import (
    absolute_url,
    cast_from_metadata,
    crew_from_metadata,
    custom_backdrop_url_for_user,
    custom_poster_url_for_user,
    details_for_api,
    episodes_from_metadata,
    find_item,
    media_summary_from_provider,
    related_sections_from_payload,
    seasons_from_metadata,
    synopsis_from_payload,
)
from api.services.filters import (
    apply_person_credit_filters,
    update_item_external_ratings,
    update_item_filter_metadata,
)
from app import config
from app.models import (
    CustomBackdropPreference,
    CustomLogoPreference,
    CustomPosterPreference,
    Item,
    MediaTypes,
    Sources,
)
from app.providers import services as provider_services
from app.utils.color import build_accent_palette, compute_and_store_poster_accent

SEARCH_TTL = 60 * 60 * 6
DISCOVER_TTL = 60 * 60 * 6
DETAIL_TTL = 60 * 60 * 24
DETAIL_CACHE_VERSION = "v9"
COMPANY_SORTS = {"popularity", "release_date", "title", "average_rating"}
COMPANY_GAME_SORT_OPTIONS = [
    {"value": "popularity", "label": "Popularity"},
    {"value": "release_date", "label": "Release Date"},
    {"value": "average_rating", "label": "IGDB Rating"},
    {"value": "title", "label": "Title"},
]
COMPANY_GAME_OPTIONS_CACHE_VERSION = "v1"
POSTER_UNSUPPORTED_MESSAGE = (
    "Poster customization is only available for TMDB movies/TV shows/seasons, Open Library/Hardcover books, and IGDB games."
)
BACKDROP_UNSUPPORTED_MESSAGE = (
    "Backdrop customization is only available for TMDB movies/TV shows/seasons and IGDB games."
)
LOGO_UNSUPPORTED_MESSAGE = "Logo customization is only available for TMDB movies/TV shows and IGDB games."
logger = logging.getLogger(__name__)

RATING_URL_BASES = {
    "comicvine": "https://comicvine.gamespot.com/",
    "hardcover": "https://hardcover.app/",
    "igdb": "https://www.igdb.com/",
    "imdb": "https://www.imdb.com/",
    "letterboxd": "https://letterboxd.com/",
    "mal": "https://myanimelist.net/",
    "mangaupdates": "https://www.mangaupdates.com/",
    "metacritic": "https://www.metacritic.com/",
    "openlibrary": "https://openlibrary.org/",
    "tmdb": "https://www.themoviedb.org/",
    "tomatoes": "https://www.rottentomatoes.com/",
}
RATING_URL_HOSTS = {
    "comicvine": {"comicvine.gamespot.com"},
    "hardcover": {"hardcover.app"},
    "igdb": {"igdb.com"},
    "imdb": {"imdb.com"},
    "letterboxd": {"boxd.it", "letterboxd.com"},
    "mal": {"myanimelist.net"},
    "mangaupdates": {"mangaupdates.com"},
    "metacritic": {"metacritic.com"},
    "openlibrary": {"openlibrary.org"},
    "tmdb": {"themoviedb.org"},
    "tomatoes": {"rottentomatoes.com"},
}


def default_source_for(media_type):
    """Return the configured default source value for a media type."""
    return config.get_default_source_name(media_type).value


def search_media(*, media_type, query, page=1, source=None, request=None, user=None):
    """Search provider metadata with a versioned cache key."""
    source = source or default_source_for(media_type)
    query_hash = hashlib.sha256(query.strip().lower().encode()).hexdigest()[:24]
    cache_key = (
        f"api:v2:search:{media_type}:{source}:{query_hash}:"
        f"p{page}:u{getattr(settings, 'TMDB_LANG', 'en')}:nsfw{settings.TMDB_NSFW}"
    )
    data = cache.get(cache_key)
    if data is None:
        data = provider_services.search(media_type, query, page, source)
        cache.set(cache_key, data, SEARCH_TTL)

    raw_results = data.get("results") or data.get("items") or []
    return [
        media_summary_from_provider(
            item,
            media_type=item.get("media_type", media_type),
            source=item.get("source", source),
            request=request,
            user=user,
        )
        for item in raw_results
    ]


def discover_media(
    *,
    media_type,
    page=1,
    page_size=None,
    source=None,
    genre=None,
    year=None,
    platform=None,
    sort="vote_count",
    request=None,
    user=None,
):
    """Discover provider metadata with a versioned cache key."""
    source = source or default_source_for(media_type)
    filters = urlencode(
        {
            "genre": genre or "",
            "year": year or "",
            "platform": platform or "",
            "sort": sort,
            "page_size": page_size or "",
        },
    )
    filters_hash = hashlib.sha256(filters.encode()).hexdigest()[:24]
    cache_key = f"api:v1:discover:{media_type}:{source}:{filters_hash}:p{page}"
    data = cache.get(cache_key)
    if data is None:
        data = provider_services.discover(
            media_type,
            source=source,
            page=page,
            page_size=page_size,
            genre=genre,
            year=year,
            platform=platform,
            sort=sort,
        )
        cache.set(cache_key, data, DISCOVER_TTL)

    raw_results = data.get("results") or data.get("items") or []
    return {
        "count": data.get("total_results", len(raw_results)),
        "page_size": data.get("per_page") or page_size or len(raw_results),
        "results": [
            media_summary_from_provider(
                item,
                media_type=item.get("media_type", media_type),
                source=item.get("source", source),
                request=request,
                user=user,
            )
            for item in raw_results
        ],
    }


def media_detail(*, source, media_type, media_id, request=None, user=None, season_number=None, episode_number=None):
    """Fetch provider metadata and normalize it for the API."""
    cache_key = (
        f"api:{DETAIL_CACHE_VERSION}:detail:{source}:{media_type}:{media_id}:"
        f"s{season_number}:e{episode_number}:u{getattr(settings, 'TMDB_LANG', 'en')}"
    )
    metadata = cache.get(cache_key)
    if metadata is None:
        season_numbers = [season_number] if season_number is not None else None
        metadata = provider_services.get_media_metadata(
            media_type,
            media_id,
            source,
            season_numbers,
            episode_number,
        )
        cache.set(cache_key, metadata, DETAIL_TTL)

    item = Item.objects.filter(
        source=source,
        media_type=media_type,
        media_id=media_id,
        season_number=season_number,
        episode_number=episode_number,
    ).first()
    update_item_filter_metadata(item, metadata)

    summary = media_summary_from_provider(
        {
            **metadata,
            "media_id": media_id,
            "media_type": media_type,
            "source": source,
            "season_number": season_number,
            "episode_number": episode_number,
        },
        media_type,
        source,
        request=request,
        user=user,
    )
    synopsis = synopsis_from_payload(metadata) or summary.get("overview")
    if synopsis:
        summary["overview"] = synopsis
    ref = summary["ref"]
    if summary.get("poster_accent_color") is None:
        summary["poster_accent_color"] = poster_accent_color(metadata, ref)
    logo, custom_logo_url = resolved_logo(
        source=source,
        media_type=media_type,
        media_id=media_id,
        request=request,
        user=user,
    )
    default_backdrop_url, custom_backdrop_url = resolved_backdrop_urls(
        source=source,
        media_type=media_type,
        media_id=media_id,
        season_number=season_number,
        metadata=metadata,
        request=request,
        user=user,
    )
    return {
        **summary,
        "overview": synopsis,
        "synopsis": synopsis,
        "backdrop_url": default_backdrop_url,
        "logo_url": logo.get("url") if logo else None,
        "logo_width": logo.get("width") if logo else None,
        "logo_height": logo.get("height") if logo else None,
        "logo_aspect_ratio": logo.get("aspect_ratio") if logo else None,
        "custom_logo_url": custom_logo_url,
        "details": details_for_api(metadata),
        "cast": cast_from_metadata(metadata, request=request),
        "crew": crew_from_metadata(metadata, request=request),
        "seasons": seasons_from_metadata(metadata, request=request) if media_type == MediaTypes.TV.value else [],
        "episodes": episodes_from_metadata(enrich_episodes(metadata, source, user), request=request)
        if media_type == MediaTypes.SEASON.value
        else [],
        "custom_backdrop_url": custom_backdrop_url,
        "custom_poster_url": custom_poster_url_for_user(user, ref, request=request),
        "related": metadata.get("related", {}),
        "related_sections": related_sections_from_payload(
            metadata.get("related", {}),
            media_type=media_type,
            source=source,
            request=request,
            user=user,
        ),
        "providers": watch_providers_for_user(metadata, user),
        "community": community_stats(
            source=source,
            media_type=media_type,
            media_id=media_id,
            season_number=season_number,
        ),
        "external_ratings": external_ratings(
            metadata=metadata,
            source=source,
            media_type=media_type,
            media_id=media_id,
            season_number=season_number,
        ),
    }


def person_detail(*, source, person_id, request=None, user=None, params=None):
    """Return a provider person profile plus iOS-ready media summaries."""
    if source not in {Sources.TMDB.value, Sources.HARDCOVER.value, Sources.OPENLIBRARY.value}:
        msg = "People pages are only supported for TMDB, Hardcover, and OpenLibrary in v1."
        raise NotImplementedError(msg)

    person = provider_services.get_person_page(source, person_id)
    person_credits = apply_person_credit_filters(person.get("credits") or [], params or {})
    return {
        "id": str(person.get("person_id") or person_id),
        "source": source,
        "name": person.get("name") or "",
        "biography": person.get("biography"),
        "profile_url": absolute_url(request, person.get("image")),
        "known_for_department": person.get("known_for_department"),
        "birth_date": person.get("birth_date"),
        "death_date": person.get("death_date"),
        "place_of_birth": person.get("place_of_birth"),
        "popularity": person.get("popularity"),
        "credits": {
            "cast": [
                media_summary_from_provider(
                    credit,
                    media_type=credit.get("media_type"),
                    source=credit.get("source", source),
                    request=request,
                    user=user,
                )
                for credit in person_credits
                if credit.get("media_type") in {MediaTypes.MOVIE.value, MediaTypes.TV.value, MediaTypes.BOOK.value}
            ],
        },
    }


def company_detail(*, source, company_id):
    """Return an IGDB company profile for native studio pages."""
    if source != Sources.IGDB.value:
        msg = "Company pages are only supported for IGDB in v1."
        raise NotImplementedError(msg)

    company = provider_services.get_company(source, company_id)
    logo = company.get("logo") or {}
    parent = company.get("parent") or {}
    return {
        "id": str(company.get("id") or company_id),
        "source": source,
        "name": company.get("name") or "",
        "description": company.get("description") or None,
        "logo_url": _company_logo_url(logo),
        "logo_width": logo.get("width") or None,
        "logo_height": logo.get("height") or None,
        "founded_year": _company_founded_year(company.get("start_date")),
        "country_code": company.get("country"),
        "status": (company.get("status") or {}).get("name"),
        "company_size": (company.get("company_size") or {}).get("name"),
        "parent": (
            {"id": str(parent["id"]), "name": parent.get("name") or ""}
            if parent.get("id") is not None
            else None
        ),
        "igdb_url": company.get("url") or None,
        "websites": [
            website["url"]
            for website in company.get("websites") or []
            if isinstance(website, dict) and website.get("url")
        ],
        "catalogs": {
            "developed": {"count": provider_services.company_catalog_count(source, company, "developed")},
            "published": {"count": provider_services.company_catalog_count(source, company, "published")},
        },
    }


def company_games(
    *,
    source,
    company_id,
    role,
    sort="popularity",
    direction=None,
    params=None,
    request=None,
    user=None,
):
    """Return sorted native media summaries for a company catalogue role."""
    if source != Sources.IGDB.value:
        msg = "Company pages are only supported for IGDB in v1."
        raise NotImplementedError(msg)
    if role not in {"developed", "published"}:
        raise ValueError("role must be developed or published.")
    if sort not in COMPANY_SORTS:
        raise ValueError("sort must be popularity, release_date, title, or average_rating.")
    if direction not in {None, "asc", "desc"}:
        raise ValueError("direction must be asc or desc.")

    direction = direction or ("asc" if sort == "title" else "desc")
    catalog = provider_services.get_company_catalog(source, company_id, role)
    filtered = _filter_company_catalog(catalog, params or {})
    ordered = _sort_company_catalog(filtered, sort=sort, direction=direction)
    return [
        media_summary_from_provider(
            game,
            media_type=MediaTypes.GAME.value,
            source=Sources.IGDB.value,
            request=request,
            user=user,
        )
        for game in ordered
    ]


def company_game_filter_options(*, source, company_id):
    """Return complete choices across a company's developed and published games."""
    if source != Sources.IGDB.value:
        msg = "Company pages are only supported for IGDB in v1."
        raise NotImplementedError(msg)

    cache_key = f"company_game_options_{source}_{company_id}_{COMPANY_GAME_OPTIONS_CACHE_VERSION}"
    cached = cache.get(cache_key)
    if cached is not None:
        return cached

    games_by_id = {}
    for role in ("developed", "published"):
        for game in provider_services.get_company_catalog(source, company_id, role):
            games_by_id.setdefault(str(game.get("media_id") or ""), game)

    games = games_by_id.values()
    genres = sorted({value for game in games for value in game.get("genres") or []}, key=str.casefold)
    platforms = sorted({value for game in games for value in game.get("platforms") or []}, key=str.casefold)
    years = sorted(
        {
            int(str(game["release_date"])[:4])
            for game in games
            if game.get("release_date") and str(game["release_date"])[:4].isdigit()
        },
        reverse=True,
    )
    options = {
        "sorts": COMPANY_GAME_SORT_OPTIONS,
        "genres": [{"value": value, "label": value} for value in genres],
        "languages": [],
        "platforms": [{"value": value, "label": value} for value in platforms],
        "years": years,
    }
    cache.set(cache_key, options, DETAIL_TTL)
    return options


def _company_logo_url(logo):
    url = logo.get("url") if isinstance(logo, dict) else None
    if url:
        normalized = f"https:{url}" if url.startswith("//") else url
        parts = urlsplit(normalized)
        path = parts.path.replace("/t_thumb/", "/t_logo_med/")
        filename = path.rsplit("/", 1)[-1]
        if "." in filename:
            path = path.rsplit(".", 1)[0]
        return urlunsplit(parts._replace(path=f"{path}.png"))
    image_id = logo.get("image_id") if isinstance(logo, dict) else None
    if image_id:
        return f"https://images.igdb.com/igdb/image/upload/t_logo_med/{image_id}.png"
    return None


def _company_founded_year(value):
    try:
        return datetime.fromtimestamp(int(value), tz=UTC).year
    except (TypeError, ValueError, OSError, OverflowError):
        return None


def _sort_company_catalog(catalog, *, sort, direction):
    descending = direction == "desc"
    if sort == "title":
        return sorted(catalog, key=lambda game: (game.get("title") or "").casefold(), reverse=descending)

    if sort == "popularity":
        key = "vote_count"
    elif sort == "release_date":
        key = "release_date"
    else:
        key = "vote_average"
    known = [game for game in catalog if game.get(key) not in (None, "")]
    unknown = [game for game in catalog if game.get(key) in (None, "")]
    if sort == "release_date":
        known.sort(key=lambda game: game[key], reverse=descending)
    else:
        known.sort(key=lambda game: float(game[key]), reverse=descending)
    return [*known, *unknown]


def _filter_company_catalog(catalog, params):
    year = _company_int_param(params, "year")
    release_status = params.get("release_status")
    if release_status not in {None, "", "released", "unreleased"}:
        raise ValueError("release_status must be released or unreleased.")
    rating_min = _company_decimal_param(params, "rating_min")
    rating_max = _company_decimal_param(params, "rating_max")
    if (rating_min is not None and not 0 <= rating_min <= 100) or (
        rating_max is not None and not 0 <= rating_max <= 100
    ):
        raise ValueError("rating_min and rating_max must be between 0 and 100.")
    if rating_min is not None and rating_max is not None and rating_min > rating_max:
        raise ValueError("rating_min must be less than or equal to rating_max.")

    genres = set(_company_query_values(params, "genre"))
    excluded_genres = set(_company_query_values(params, "exclude_genre"))
    platforms = set(_company_query_values(params, "platform"))
    excluded_platforms = set(_company_query_values(params, "exclude_platform"))
    today = datetime.now(tz=UTC).date()

    return [
        game
        for game in catalog
        if _company_game_matches(
            game,
            year=year,
            release_status=release_status,
            rating_min=rating_min,
            rating_max=rating_max,
            genres=genres,
            excluded_genres=excluded_genres,
            platforms=platforms,
            excluded_platforms=excluded_platforms,
            today=today,
        )
    ]


def _company_game_matches(  # noqa: C901, PLR0911
    game,
    *,
    year,
    release_status,
    rating_min,
    rating_max,
    genres,
    excluded_genres,
    platforms,
    excluded_platforms,
    today,
):
    game_genres = set(game.get("genres") or [])
    game_platforms = set(game.get("platforms") or [])
    if genres and genres.isdisjoint(game_genres):
        return False
    if excluded_genres and not excluded_genres.isdisjoint(game_genres):
        return False
    if platforms and platforms.isdisjoint(game_platforms):
        return False
    if excluded_platforms and not excluded_platforms.isdisjoint(game_platforms):
        return False

    release_date = _company_release_date(game.get("release_date"))
    if year is not None and (release_date is None or release_date.year != year):
        return False
    if release_status == "released" and (release_date is None or release_date > today):
        return False
    if release_status == "unreleased" and (release_date is None or release_date <= today):
        return False

    rating = game.get("vote_average")
    if rating_min is not None or rating_max is not None:
        if rating in {None, ""}:
            return False
        rating = Decimal(str(rating))
        if rating_min is not None and rating < rating_min:
            return False
        if rating_max is not None and rating > rating_max:
            return False
    return True


def _company_query_values(params, key):
    if hasattr(params, "getlist"):
        return [value for value in params.getlist(key) if value not in {None, ""}]
    value = params.get(key)
    return [value] if value not in {None, ""} else []


def _company_int_param(params, key):
    value = params.get(key)
    if value in {None, ""}:
        return None
    try:
        return int(value)
    except (TypeError, ValueError) as error:
        message = f"{key} must be an integer."
        raise ValueError(message) from error


def _company_decimal_param(params, key):
    value = params.get(key)
    if value in {None, ""}:
        return None
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError) as error:
        message = f"{key} must be a number."
        raise ValueError(message) from error


def _company_release_date(value):
    if isinstance(value, date):
        return value
    if not value:
        return None
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def poster_options(*, source, media_type, media_id, season_number=None, request=None, user=None):
    """Return selectable posters for supported media."""
    if _supports_book_posters(source, media_type):
        options = book_cover_options(
            source=source,
            media_id=media_id,
            request=request,
            user=user,
        )
        return {"posters": options["posters"]}
    if _supports_game_posters(source, media_type):
        options = game_cover_options(source=source, media_id=media_id, request=request, user=user)
        return {"posters": options["posters"]}
    if source != Sources.TMDB.value or media_type not in [MediaTypes.MOVIE.value, MediaTypes.TV.value, MediaTypes.SEASON.value]:
        raise ValueError(POSTER_UNSUPPORTED_MESSAGE)
    season_number = _required_season_number(media_type, season_number)

    item = _customizable_item(source=source, media_type=media_type, media_id=media_id, season_number=season_number)
    from app.providers import tmdb

    current = CustomPosterPreference.objects.filter(user=user, item=item).first()
    selected_url = current.custom_image_url if current else item.image
    original = {
        "url": absolute_poster_url(request, item.image),
        "thumbnail_url": absolute_poster_url(request, item.image),
        "width": 0,
        "height": 0,
        "aspect_ratio": 0.667,
        "vote_average": 0,
        "vote_count": 0,
        "language": None,
        "is_original": True,
        "is_selected": item.image == selected_url,
    }

    posters = [original]
    for poster in tmdb.get_poster_images(media_id, media_type, season_number):
        if poster["url"] == item.image:
            continue
        posters.append(
            {
                **poster,
                "language": poster.get("language"),
                "is_original": False,
                "is_selected": poster["url"] == selected_url,
            },
        )
    return {"posters": posters}


def save_poster_preference(*, source, media_type, media_id, poster_url, user, season_number=None):
    """Save a user's poster preference and update the stored item image/accent."""
    if (
        source != Sources.TMDB.value
        or media_type not in [MediaTypes.MOVIE.value, MediaTypes.TV.value, MediaTypes.SEASON.value]
    ) and not _supports_book_posters(source, media_type) and not _supports_game_posters(source, media_type):
        raise ValueError(POSTER_UNSUPPORTED_MESSAGE)
    season_number = _required_season_number(media_type, season_number)
    if not poster_url:
        raise ValueError("poster_url is required.")

    item = _customizable_item(source=source, media_type=media_type, media_id=media_id, season_number=season_number)
    accent = compute_and_store_poster_accent(item, poster_url=poster_url, force=True)
    palette = build_accent_palette(accent)
    CustomPosterPreference.objects.update_or_create(
        user=user,
        item=item,
        defaults={"custom_image_url": poster_url},
    )
    item.image = poster_url
    item.poster_accent_color = palette["accent"]
    item.save(update_fields=["image", "poster_accent_color"])
    return {
        "poster_url": poster_url,
        "custom_poster_url": poster_url,
        "poster_accent_color": palette["accent"],
    }


def book_cover_options(*, source, media_id, request=None, user=None):
    """Return selectable covers for Open Library/Hardcover books."""
    media_type = MediaTypes.BOOK.value
    if not _supports_book_posters(source, media_type):
        raise ValueError(POSTER_UNSUPPORTED_MESSAGE)

    item = _customizable_item(source=source, media_type=media_type, media_id=media_id)
    isbns = _book_isbns(source, media_id)
    current = CustomPosterPreference.objects.filter(user=user, item=item).first()
    selected_url = current.custom_image_url if current else item.image
    selected_absolute = absolute_poster_url(request, selected_url)

    posters = []
    seen = set()
    covers = [
        {"url": item.image, "thumbnail_url": item.image, "is_original": True},
        *_book_cover_candidates(source, media_id, isbns),
    ]
    for cover in covers:
        url = cover.get("url")
        if not url or url in seen:
            continue
        seen.add(url)
        absolute_url = absolute_poster_url(request, url)
        posters.append(
            {
                "url": absolute_url,
                "thumbnail_url": absolute_poster_url(request, cover.get("thumbnail_url") or url),
                "width": cover.get("width") or 0,
                "height": cover.get("height") or 0,
                "aspect_ratio": cover.get("aspect_ratio") or 0.667,
                "vote_average": cover.get("vote_average") or 0,
                "vote_count": cover.get("vote_count") or 0,
                "language": cover.get("language"),
                "is_original": bool(cover.get("is_original")),
                "is_selected": absolute_url == selected_absolute,
            },
        )
    return {"item": item, "posters": posters, "current_poster": selected_url}


def game_cover_options(*, source, media_id, request=None, user=None):
    """Return selectable covers for IGDB games."""
    if not _supports_game_posters(source, MediaTypes.GAME.value):
        raise ValueError(POSTER_UNSUPPORTED_MESSAGE)

    item = _customizable_item(source=source, media_type=MediaTypes.GAME.value, media_id=media_id)
    current = CustomPosterPreference.objects.filter(user=user, item=item).first()
    selected_url = current.custom_image_url if current else item.image
    selected_absolute = absolute_poster_url(request, selected_url)
    from app.providers import igdb, steamgriddb

    posters = []
    seen = set()
    covers = [
        {"url": item.image, "thumbnail_url": item.image, "is_original": True},
        *steamgriddb.get_game_posters(media_id),
        *igdb.get_game_covers(media_id),
    ]
    for cover in covers:
        url = cover.get("url")
        if not url or url in seen:
            continue
        seen.add(url)
        absolute_url = absolute_poster_url(request, url)
        posters.append(
            {
                "url": absolute_url,
                "thumbnail_url": absolute_poster_url(request, cover.get("thumbnail_url") or url),
                "width": cover.get("width") or 0,
                "height": cover.get("height") or 0,
                "aspect_ratio": cover.get("aspect_ratio") or 0.667,
                "vote_average": cover.get("vote_average") or 0,
                "vote_count": cover.get("vote_count") or 0,
                "language": cover.get("language"),
                "is_original": bool(cover.get("is_original")),
                "is_selected": absolute_url == selected_absolute,
            },
        )
    return {"item": item, "posters": posters, "current_poster": selected_url}


def backdrop_options(*, source, media_type, media_id, season_number=None, request=None, user=None):
    """Return selectable backdrops for supported media."""
    if _supports_game_backdrops(source, media_type):
        return game_backdrop_options(source=source, media_id=media_id, request=request, user=user)
    if source != Sources.TMDB.value or media_type not in [
        MediaTypes.MOVIE.value,
        MediaTypes.TV.value,
        MediaTypes.SEASON.value,
    ]:
        raise ValueError(BACKDROP_UNSUPPORTED_MESSAGE)
    season_number = _required_season_number(media_type, season_number)

    item = _customizable_item(source=source, media_type=media_type, media_id=media_id, season_number=season_number)
    metadata = provider_services.get_media_metadata(
        "tv_with_seasons" if media_type == MediaTypes.SEASON.value else media_type,
        media_id,
        source,
        [season_number] if media_type == MediaTypes.SEASON.value else None,
    )
    if media_type == MediaTypes.SEASON.value:
        metadata = metadata[f"season/{season_number}"]
    raw_default_url = backdrop_url(metadata)
    from app.providers import tmdb

    tmdb_backdrops = (
        tmdb.get_season_backdrop_images(media_id, season_number)
        if media_type == MediaTypes.SEASON.value
        else tmdb.get_backdrop_images(media_id, media_type)
    )
    default_url, custom_url = resolved_backdrop_urls(
        source=source,
        media_type=media_type,
        media_id=media_id,
        season_number=season_number,
        metadata=metadata,
        request=request,
        user=user,
        item=item,
        tmdb_backdrops=tmdb_backdrops,
    )
    selected_url = custom_url or default_url
    original = {
        "url": raw_default_url,
        "thumbnail_url": raw_default_url,
        "width": 0,
        "height": 0,
        "aspect_ratio": 1.778,
        "vote_average": 0,
        "vote_count": 0,
        "language": None,
        "is_original": True,
        "is_selected": raw_default_url == selected_url,
    }

    backdrops = [original] if raw_default_url else []
    for backdrop in tmdb_backdrops:
        if backdrop["url"] == raw_default_url:
            continue
        backdrops.append(
            {
                **backdrop,
                "language": backdrop.get("language"),
                "is_original": False,
                "is_selected": backdrop["url"] == selected_url,
            },
        )
    return {"backdrops": backdrops}


def game_backdrop_options(*, source, media_id, request=None, user=None):
    """Return selectable IGDB artwork images for game backdrops."""
    if not _supports_game_backdrops(source, MediaTypes.GAME.value):
        raise ValueError(BACKDROP_UNSUPPORTED_MESSAGE)

    item = _customizable_item(source=source, media_type=MediaTypes.GAME.value, media_id=media_id)
    metadata = provider_services.get_media_metadata(MediaTypes.GAME.value, media_id, source)
    raw_default_url = backdrop_url(metadata)
    from app.providers import igdb, steamgriddb

    igdb_backdrops = igdb.get_game_backdrops(media_id)
    steamgriddb_backdrops = steamgriddb.get_game_backdrops(media_id)
    default_url, custom_url = resolved_backdrop_urls(
        source=source,
        media_type=MediaTypes.GAME.value,
        media_id=media_id,
        metadata=metadata,
        request=request,
        user=user,
        item=item,
    )
    selected_url = custom_url or default_url
    backdrops = []
    seen = set()
    candidates = [
        {
            "url": raw_default_url,
            "thumbnail_url": raw_default_url,
            "width": 0,
            "height": 0,
            "aspect_ratio": 1.778,
            "vote_average": 0,
            "vote_count": 0,
            "language": None,
            "is_original": True,
        },
        *steamgriddb_backdrops,
        *igdb_backdrops,
    ]
    for candidate in candidates:
        url = candidate.get("url")
        if not url or url in seen:
            continue
        seen.add(url)
        backdrops.append(
            {
                **candidate,
                "language": candidate.get("language"),
                "is_original": bool(candidate.get("is_original")),
                "is_selected": url == selected_url,
            },
        )
    return {"backdrops": backdrops}


def save_backdrop_preference(*, source, media_type, media_id, backdrop_url, user, season_number=None):
    """Save a user's backdrop preference without mutating the item poster."""
    if (
        source != Sources.TMDB.value or media_type not in [
            MediaTypes.MOVIE.value,
            MediaTypes.TV.value,
            MediaTypes.SEASON.value,
        ]
    ) and not _supports_game_backdrops(source, media_type):
        raise ValueError(BACKDROP_UNSUPPORTED_MESSAGE)
    season_number = _required_season_number(media_type, season_number)
    if not backdrop_url:
        raise ValueError("backdrop_url is required.")

    item = _customizable_item(source=source, media_type=media_type, media_id=media_id, season_number=season_number)
    CustomBackdropPreference.objects.update_or_create(
        user=user,
        item=item,
        defaults={"custom_image_url": backdrop_url},
    )
    return {
        "backdrop_url": backdrop_url,
        "custom_backdrop_url": backdrop_url,
    }


def logo_options(*, source, media_type, media_id, request=None, user=None):
    """Return selectable title logos for supported media."""
    _require_logo_support(source, media_type)
    item = _customizable_item(source=source, media_type=media_type, media_id=media_id)
    provider_logos = _provider_logo_options(source, media_type, media_id)
    automatic = title_logo(source=source, media_type=media_type, media_id=media_id)
    preference = CustomLogoPreference.objects.filter(user=user, item=item).first()
    selected_url = preference.custom_image_url if preference else automatic.get("url") if automatic else None
    automatic_url = automatic.get("url") if automatic else None

    logos = [
        {
            **logo,
            "style": logo.get("style"),
            "is_original": logo["url"] == automatic_url,
            "is_selected": logo["url"] == selected_url,
        }
        for logo in provider_logos
    ]
    if selected_url and not any(logo["url"] == selected_url for logo in logos):
        logos.insert(
            0,
            {
                "url": absolute_url(request, selected_url),
                "thumbnail_url": absolute_url(request, selected_url),
                "width": 0,
                "height": 0,
                "aspect_ratio": None,
                "vote_average": 0,
                "vote_count": 0,
                "language": None,
                "style": None,
                "is_original": False,
                "is_selected": True,
            },
        )
    return {"logos": logos}


def save_logo_preference(*, source, media_type, media_id, logo_url, user):
    """Save a user's title logo preference."""
    _require_logo_support(source, media_type)
    _validate_logo_url(logo_url)
    item = _customizable_item(source=source, media_type=media_type, media_id=media_id)
    CustomLogoPreference.objects.update_or_create(
        user=user,
        item=item,
        defaults={"custom_image_url": logo_url},
    )
    try:
        matched = next(
            (logo for logo in _provider_logo_options(source, media_type, media_id) if logo["url"] == logo_url),
            None,
        )
    except provider_services.ProviderAPIError:
        matched = None
    return {
        "logo_url": logo_url,
        "custom_logo_url": logo_url,
        "logo_width": matched.get("width") if matched else None,
        "logo_height": matched.get("height") if matched else None,
        "logo_aspect_ratio": matched.get("aspect_ratio") if matched else None,
    }


def resolved_logo(*, source, media_type, media_id, request=None, user=None):
    """Return effective logo metadata and the viewer's custom URL."""
    automatic = title_logo(source=source, media_type=media_type, media_id=media_id)
    if not _supports_logo(source, media_type) or not user or not user.is_authenticated:
        return automatic, None

    item = Item.objects.filter(
        source=source,
        media_type=media_type,
        media_id=media_id,
        season_number=None,
        episode_number=None,
    ).first()
    preference = (
        CustomLogoPreference.objects.filter(user=user, item=item).first()
        if item is not None
        else None
    )
    if preference is None:
        return automatic, None

    custom_url = absolute_url(request, preference.custom_image_url)
    matched = next(
        (
            logo
            for logo in _provider_logo_options(source, media_type, media_id)
            if logo["url"] == preference.custom_image_url
        ),
        None,
    )
    if matched:
        return {**matched, "url": custom_url}, custom_url
    return {
        "url": custom_url,
        "width": None,
        "height": None,
        "aspect_ratio": None,
    }, custom_url


def _provider_logo_options(source, media_type, media_id):
    if source == Sources.TMDB.value:
        from app.providers import tmdb

        return tmdb.get_title_logos(media_id, media_type)
    from app.providers import steamgriddb

    return steamgriddb.get_game_logos(media_id)


def _supports_logo(source, media_type):
    return (
        source == Sources.TMDB.value
        and media_type in [MediaTypes.MOVIE.value, MediaTypes.TV.value]
    ) or (source == Sources.IGDB.value and media_type == MediaTypes.GAME.value)


def _require_logo_support(source, media_type):
    if not _supports_logo(source, media_type):
        raise ValueError(LOGO_UNSUPPORTED_MESSAGE)


def _validate_logo_url(logo_url):
    if not isinstance(logo_url, str) or not logo_url:
        raise ValueError("logo_url is required.")
    if len(logo_url) > CustomLogoPreference._meta.get_field("custom_image_url").max_length:
        raise ValueError("logo_url must be 500 characters or fewer.")
    try:
        URLValidator(schemes=["http", "https"])(logo_url)
    except ValidationError as error:
        raise ValueError("logo_url must be a valid absolute HTTP(S) URL.") from error


def _customizable_item(*, source, media_type, media_id, season_number=None):
    item = Item.objects.filter(
        source=source,
        media_type=media_type,
        media_id=media_id,
        season_number=season_number,
    ).first()
    if item is not None:
        return item
    metadata = provider_services.get_media_metadata(
        "tv_with_seasons" if media_type == MediaTypes.SEASON.value else media_type,
        media_id,
        source,
        [season_number] if media_type == MediaTypes.SEASON.value else None,
    )
    if media_type == MediaTypes.SEASON.value:
        metadata = metadata[f"season/{season_number}"]
    return Item.objects.create(
        media_id=media_id,
        source=source,
        media_type=media_type,
        title=metadata.get("title") or metadata.get("name") or media_id,
        image=metadata.get("image") or settings.IMG_NONE,
        season_number=season_number,
    )


def _required_season_number(media_type, season_number):
    if media_type != MediaTypes.SEASON.value:
        return None
    if season_number in [None, ""]:
        raise ValueError("season_number is required for seasons.")
    return int(season_number)


def _supports_book_posters(source, media_type):
    return media_type == MediaTypes.BOOK.value and source in [
        Sources.OPENLIBRARY.value,
        Sources.HARDCOVER.value,
    ]


def _supports_game_posters(source, media_type):
    return media_type == MediaTypes.GAME.value and source == Sources.IGDB.value


def _supports_game_backdrops(source, media_type):
    return media_type == MediaTypes.GAME.value and source == Sources.IGDB.value


def _book_isbns(source, media_id):
    if source == Sources.HARDCOVER.value:
        from app.providers import hardcover

        return hardcover.get_book_isbns(media_id)
    if source == Sources.OPENLIBRARY.value:
        metadata = provider_services.get_media_metadata(MediaTypes.BOOK.value, media_id, source)
        return metadata.get("details", {}).get("isbn", []) or []
    return []


def _book_cover_candidates(source, media_id, isbns):
    from app.providers import openlibrary

    try:
        if source == Sources.OPENLIBRARY.value:
            return asyncio.run(openlibrary.get_reliable_covers_for_book(media_id, isbns, cap=20))
        return asyncio.run(openlibrary.get_reliable_covers_by_isbns(isbns, cap=20))
    except (ClientError, OSError, RuntimeError, TimeoutError, ValueError) as error:
        logger.warning("Reliable cover fetch failed, falling back to ISBN covers: %s", error)
        return openlibrary.get_book_cover_images(isbns)


def absolute_poster_url(request, url):
    """Return an absolute poster URL without substituting the global placeholder."""
    if not url:
        return None
    if str(url).startswith(("http://", "https://")):
        return url
    return request.build_absolute_uri(url) if request is not None else url


def backdrop_url(metadata):
    """Return an absolute backdrop URL when available."""
    value = metadata.get("backdrop") or metadata.get("backdrop_url") or metadata.get("backdrop_path")
    if not value:
        for artwork in metadata.get("artworks") or []:
            if isinstance(artwork, dict) and artwork.get("image_id"):
                return f"https://images.igdb.com/igdb/image/upload/t_original/{artwork['image_id']}.jpg"
    if isinstance(value, str) and value.startswith("/"):
        return f"https://image.tmdb.org/t/p/original{value}"
    return value


def _game_default_backdrop_url(media_id, raw_default_url=None):
    if raw_default_url:
        return raw_default_url
    from app.providers import igdb, steamgriddb

    for backdrop in [*steamgriddb.get_game_backdrops(media_id), *igdb.get_game_backdrops(media_id)]:
        if backdrop.get("url"):
            return backdrop["url"]
    return None


def resolved_backdrop_urls(
    *,
    source,
    media_type,
    media_id,
    metadata,
    season_number=None,
    request=None,
    user=None,
    item=None,
    tmdb_backdrops=None,
):
    """Return the resolved default backdrop and viewer custom backdrop."""
    raw_default_url = backdrop_url(metadata)
    if _supports_game_backdrops(source, media_type):
        raw_default_url = _game_default_backdrop_url(media_id, raw_default_url)
    if source != Sources.TMDB.value or media_type not in [
        MediaTypes.MOVIE.value,
        MediaTypes.TV.value,
        MediaTypes.SEASON.value,
    ]:
        return raw_default_url, custom_backdrop_url_for_user(
            user,
            {
                "source": source,
                "media_type": media_type,
                "media_id": media_id,
                "season_number": season_number,
            },
            request=request,
        )

    item = item or Item.objects.filter(
        source=source,
        media_type=media_type,
        media_id=media_id,
        season_number=season_number,
    ).first()
    custom_url = _backdrop_preference_url(user, item, request=request)
    if media_type == MediaTypes.SEASON.value:
        if tmdb_backdrops is None and season_number is not None:
            from app.providers import tmdb

            tmdb_backdrops = tmdb.get_season_backdrop_images(media_id, season_number)
        default_url = (
            _curated_backdrop_url(item, request=request)
            or (tmdb_backdrops[0]["url"] if tmdb_backdrops else None)
            or raw_default_url
        )
        return default_url, custom_url
    default_url = (
        _curated_backdrop_url(item, request=request)
        or _tmdb_vote_sorted_backdrop_url(
            media_id,
            media_type,
            raw_default_url=raw_default_url,
            tmdb_backdrops=tmdb_backdrops,
        )
    )
    return default_url, custom_url


def _backdrop_preference_url(user, item, request=None):
    if not user or not user.is_authenticated or item is None:
        return None
    preference = CustomBackdropPreference.objects.filter(user=user, item=item).first()
    return absolute_url(request, preference.custom_image_url) if preference else None


def _curated_backdrop_url(item, request=None):
    curator_username = getattr(settings, "SPINE_CURATOR_USERNAME", None)
    if not curator_username or item is None:
        return None
    preference = CustomBackdropPreference.objects.filter(
        user__username=curator_username,
        item=item,
    ).first()
    return absolute_url(request, preference.custom_image_url) if preference else None


def _tmdb_vote_sorted_backdrop_url(media_id, media_type, *, raw_default_url=None, tmdb_backdrops=None):
    if tmdb_backdrops is None:
        from app.providers import tmdb

        tmdb_backdrops = tmdb.get_backdrop_images(media_id, media_type)
    tmdb_backdrops = [backdrop for backdrop in tmdb_backdrops if backdrop.get("language") is None]
    if len(tmdb_backdrops) > 1:
        return tmdb_backdrops[1]["url"]
    if tmdb_backdrops:
        return raw_default_url or tmdb_backdrops[0]["url"]
    return raw_default_url


def title_logo(*, source, media_type, media_id):
    """Return title logo metadata for supported detail responses."""
    if source == Sources.TMDB.value and media_type in [MediaTypes.MOVIE.value, MediaTypes.TV.value]:
        from app.providers import tmdb

        return tmdb.get_title_logo(media_id, media_type)
    if source == Sources.IGDB.value and media_type == MediaTypes.GAME.value:
        from app.providers import steamgriddb

        return steamgriddb.get_game_logo(media_id)
    return None


def poster_accent_color(metadata, ref):
    """Compute an accent only when there is no stored Item color."""
    item = find_item(ref)
    if item is not None and item.poster_accent_color:
        return item.poster_accent_color
    return None


def watch_providers_for_user(metadata, user):
    """Return provider availability, region-filtered for authenticated users."""
    providers = metadata.get("providers")
    if not providers:
        return providers
    region = getattr(user, "watch_provider_region", None) if user and user.is_authenticated else None
    if not region or region == "UNSET":
        return providers
    from app.providers import tmdb

    return tmdb.filter_providers(deepcopy(providers), region)


def enrich_episodes(metadata, source, user):
    """Apply provider episode formatting when tracking rows exist."""
    if not metadata.get("episodes"):
        return metadata
    from app.models import BasicMedia
    from app.providers import manual, tmdb

    episodes_in_db = []
    if user and user.is_authenticated:
        current = BasicMedia.objects.filter_media(
            user,
            metadata.get("media_id"),
            MediaTypes.SEASON.value,
            source,
            metadata.get("season_number"),
        ).first()
        episodes_in_db = current.episodes.all() if current else []

    payload = dict(metadata)
    if source == "manual":
        payload["episodes"] = manual.process_episodes(metadata, episodes_in_db)
    elif source == "tmdb":
        payload["episodes"] = tmdb.process_episodes(metadata, episodes_in_db)
    return payload


def _is_allowed_rating_host(host, allowed_hosts):
    return any(host == allowed or host.endswith(f".{allowed}") for allowed in allowed_hosts)


def _is_valid_rating_path(source, path):
    if source != "imdb":
        return True

    segments = [segment for segment in path.split("/") if segment]
    return (
        len(segments) == 2
        and segments[0] == "title"
        and segments[1].startswith("tt")
        and segments[1][2:].isdigit()
    )


def _safe_urlsplit(value):
    try:
        return urlsplit(value)
    except ValueError:
        return None


def _absolute_rating_url(source, candidate, allowed_hosts):
    parsed = _safe_urlsplit(candidate)
    if parsed is None:
        return None
    if parsed.scheme:
        return candidate
    if candidate.startswith("//"):
        return f"https:{candidate}"

    first_segment = candidate.lstrip("/").split("/", 1)[0].lower()
    if _is_allowed_rating_host(first_segment, allowed_hosts):
        return f"https://{candidate.lstrip('/')}"
    return urljoin(RATING_URL_BASES[source], candidate)


def _normalize_rating_url(source, value):
    """Return a trusted absolute HTTPS URL for a known rating provider."""
    source = str(source).lower()
    allowed_hosts = RATING_URL_HOSTS.get(source)
    candidate = str(value or "").strip()
    if not allowed_hosts or not candidate:
        return None

    candidate = _absolute_rating_url(source, candidate, allowed_hosts)
    parsed = _safe_urlsplit(candidate) if candidate else None
    if parsed is None:
        return None
    host = (parsed.hostname or "").lower().rstrip(".")
    if (
        parsed.scheme.lower() not in {"http", "https"}
        or not host
        or parsed.username
        or parsed.password
        or not _is_allowed_rating_host(host, allowed_hosts)
        or not _is_valid_rating_path(source, parsed.path)
    ):
        return None

    if parsed.scheme.lower() == "http":
        parsed = parsed._replace(scheme="https")
    return parsed.geturl()


def _provider_rating_fallback(*, source, media_type, media_id, season_number=None):
    encoded_id = quote(str(media_id), safe="")
    if source == Sources.TMDB.value and media_type == MediaTypes.SEASON.value:
        return (
            f"https://www.themoviedb.org/tv/{encoded_id}/season/{season_number}"
            if season_number is not None
            else None
        )

    return {
        (Sources.TMDB.value, MediaTypes.MOVIE.value): f"https://www.themoviedb.org/movie/{encoded_id}",
        (Sources.TMDB.value, MediaTypes.TV.value): f"https://www.themoviedb.org/tv/{encoded_id}",
        (Sources.MAL.value, MediaTypes.ANIME.value): f"https://myanimelist.net/anime/{encoded_id}",
        (Sources.MAL.value, MediaTypes.MANGA.value): f"https://myanimelist.net/manga/{encoded_id}",
        (Sources.OPENLIBRARY.value, MediaTypes.BOOK.value): f"https://openlibrary.org/books/{encoded_id}",
        (Sources.HARDCOVER.value, MediaTypes.BOOK.value): f"https://hardcover.app/book/{encoded_id}",
    }.get((source, media_type))


def _provider_rating_url(*, metadata, source, media_type, media_id, season_number=None):
    """Return the provider page for its own rating, without guessing slug-based URLs."""
    if url := _normalize_rating_url(source, metadata.get("source_url")):
        return url

    fallback = _provider_rating_fallback(
        source=source,
        media_type=media_type,
        media_id=media_id,
        season_number=season_number,
    )

    return _normalize_rating_url(source, fallback)


def _third_party_rating_url(*, metadata, rating_source, rating, media_type, media_id):
    """Prefer MDBList's provider URL, then use identifiers already resolved by TMDB."""
    if url := _normalize_rating_url(rating_source, rating.get("url")):
        return url

    external_links = metadata.get("external_links") or {}
    fallback = None
    if rating_source == "imdb":
        fallback = external_links.get("IMDb") or external_links.get("imdb")
    elif rating_source == "letterboxd" and media_type == MediaTypes.MOVIE.value:
        fallback = external_links.get("Letterboxd") or external_links.get("letterboxd")
        if not fallback:
            fallback = f"https://letterboxd.com/tmdb/{quote(str(media_id), safe='')}"

    return _normalize_rating_url(rating_source, fallback)


def external_ratings(*, metadata, source, media_type, media_id, season_number=None):
    """Normalize provider and third-party ratings for media detail."""
    ratings = []
    score = metadata.get("score")
    if score is not None:
        ratings.append(
            {
                "source": source_label(source),
                "value": str(score),
                "vote_count": metadata.get("score_count"),
                "max_value": max_rating_value(source),
                "url": _provider_rating_url(
                    metadata=metadata,
                    source=source,
                    media_type=media_type,
                    media_id=media_id,
                    season_number=season_number,
                ),
            },
        )

    if source == "tmdb" and media_type in {MediaTypes.MOVIE.value, MediaTypes.TV.value, MediaTypes.SEASON.value}:
        from app.providers import mdblist

        mdblist_type = MediaTypes.TV.value if media_type == MediaTypes.SEASON.value else media_type
        mdblist_ratings = mdblist.get_media_ratings(media_id, mdblist_type) or {}
        update_item_external_ratings(
            source=source,
            media_type=media_type,
            media_id=media_id,
            season_number=season_number,
            ratings=mdblist_ratings,
        )
        for rating_source, rating in mdblist_ratings.items():
            value = rating.get("value") or rating.get("score")
            if value is None:
                continue
            ratings.append(
                {
                    "source": source_label(rating_source),
                    "value": str(value),
                    "vote_count": rating.get("votes"),
                    "max_value": max_rating_value(rating_source),
                    "url": _third_party_rating_url(
                        metadata=metadata,
                        rating_source=rating_source,
                        rating=rating,
                        media_type=media_type,
                        media_id=media_id,
                    ),
                },
            )

    if source == Sources.IGDB.value and media_type == MediaTypes.GAME.value:
        from app.providers import steam

        metacritic = steam.get_metacritic_rating(media_id)
        if metacritic:
            ratings.append(
                {
                    "source": source_label("metacritic"),
                    "value": str(metacritic["value"]),
                    "vote_count": None,
                    "max_value": max_rating_value("metacritic"),
                    "url": _normalize_rating_url("metacritic", metacritic.get("url")),
                },
            )

    return ratings


def source_label(source):
    """Return user-facing source names."""
    return {
        "igdb": "IGDB",
        "imdb": "IMDb",
        "letterboxd": "Letterboxd",
        "mal": "MAL",
        "mangaupdates": "MangaUpdates",
        "openlibrary": "OpenLibrary",
        "hardcover": "Hardcover",
        "metacritic": "Metacritic",
        "tmdb": "TMDB",
        "tomatoes": "Rotten Tomatoes",
    }.get(source, source.title())


def max_rating_value(source):
    """Return display max for known rating scales."""
    return {
        "hardcover": "5",
        "igdb": "100",
        "letterboxd": "5",
        "metacritic": "100",
        "openlibrary": "5",
        "tomatoes": "100%",
    }.get(source, "10")


def tv_seasons(*, source, media_id, request=None, user=None):
    """Return season summaries for a TV show."""
    detail = media_detail(
        source=source,
        media_type=MediaTypes.TV.value,
        media_id=media_id,
        request=request,
        user=user,
    )
    return {"seasons": detail.get("seasons", [])}


def season_detail(*, source, media_id, season_number, request=None, user=None):
    """Return normalized season detail."""
    return media_detail(
        source=source,
        media_type=MediaTypes.SEASON.value,
        media_id=media_id,
        season_number=season_number,
        request=request,
        user=user,
    )


def season_episodes(*, source, media_id, season_number, request=None, user=None):
    """Return episode summaries for a season."""
    detail = season_detail(
        source=source,
        media_id=media_id,
        season_number=season_number,
        request=request,
        user=user,
    )
    return {"episodes": detail.get("episodes", [])}


def community_stats(*, source, media_type, media_id, season_number=None):
    """Return current community aggregates for a media identity."""
    from app.models import DiaryEntry, Item, MediaLike

    item = Item.objects.filter(
        source=source,
        media_type=media_type,
        media_id=media_id,
        season_number=season_number,
    ).first()
    if item is None:
        return {
            "average_rating": None,
            "rating_count": 0,
            "diary_count": 0,
            "review_count": 0,
            "liked_count": 0,
            "rating_distribution": [],
        }
    entries = DiaryEntry.objects.filter(item=item).exclude(visibility="private")
    rating_values = [entry.rating for entry in entries if entry.rating is not None]
    average = round(sum(rating_values) / len(rating_values), 2) if rating_values else None
    distribution = [
        {"rating": str(bucket["rating"]), "count": bucket["count"]}
        for bucket in entries.exclude(rating__isnull=True)
        .values("rating")
        .annotate(count=Count("id"))
        .order_by("rating")
    ]
    return {
        "average_rating": str(average) if average is not None else None,
        "rating_count": len(rating_values),
        "diary_count": entries.count(),
        "review_count": entries.exclude(review="").count(),
        "liked_count": MediaLike.objects.filter(item=item).count(),
        "rating_distribution": distribution,
    }
