import logging

import requests
from django.core.cache import cache

from app import helpers
from app.models import MediaTypes, Sources
from app.providers import services

logger = logging.getLogger(__name__)

API_URL = "https://graphql.anilist.co"
FRESH_TTL = 60 * 60 * 24
STALE_TTL = 60 * 60 * 24 * 30
FAILURE_TTL = 60 * 5
REQUEST_TIMEOUT = 3
CACHE_VERSION = "v2"
PERSON_CACHE_VERSION = "v1"

ANIME_QUERY = """
query ($malId: Int!) {
  Media(idMal: $malId, type: ANIME) {
    id
    idMal
    siteUrl
    title {
      english
      romaji
      native
    }
    coverImage {
      extraLarge
      large
      medium
      color
    }
    bannerImage
    averageScore
    stats {
      scoreDistribution {
        score
        amount
      }
    }
    relations {
      edges {
        relationType
        node {
          id
          idMal
          type
          format
          siteUrl
          title {
            english
            romaji
            native
          }
          coverImage {
            extraLarge
            large
            medium
          }
          startDate {
            year
          }
        }
      }
    }
    characters(page: 1, perPage: 25, sort: [ROLE, RELEVANCE]) {
      edges {
        role
        node {
          id
          name {
            full
            native
          }
          image {
            large
            medium
          }
        }
        voiceActors(sort: [RELEVANCE, ID]) {
          id
          languageV2
          name {
            full
            native
          }
          image {
            large
            medium
          }
        }
      }
    }
  }
}
"""

MANGA_QUERY = """
query ($malId: Int!) {
  Media(idMal: $malId, type: MANGA) {
    id
    idMal
    siteUrl
    title {
      english
      romaji
      native
    }
    coverImage {
      extraLarge
      large
      medium
      color
    }
    bannerImage
    averageScore
    stats {
      scoreDistribution {
        score
        amount
      }
    }
    relations {
      edges {
        relationType
        node {
          id
          idMal
          type
          format
          siteUrl
          title {
            english
            romaji
            native
          }
          coverImage {
            extraLarge
            large
            medium
          }
          startDate {
            year
          }
        }
      }
    }
    characters(page: 1, perPage: 12, sort: [ROLE, RELEVANCE]) {
      edges {
        role
        node {
          id
          name {
            full
            native
          }
          image {
            large
            medium
          }
        }
      }
    }
    staff(page: 1, perPage: 12, sort: [RELEVANCE, ID]) {
      edges {
        role
        node {
          id
          name {
            full
            native
          }
          image {
            large
            medium
          }
        }
      }
    }
    recommendations(page: 1, perPage: 12, sort: [RATING_DESC, ID]) {
      nodes {
        mediaRecommendation {
          id
          idMal
          type
          siteUrl
          title {
            english
            romaji
            native
          }
          coverImage {
            extraLarge
            large
            medium
          }
          startDate {
            year
          }
        }
      }
    }
  }
}
"""

STAFF_QUERY = """
query ($id: Int!, $page: Int!) {
  Staff(id: $id) {
    id
    name {
      full
      native
      alternative
    }
    image {
      large
      medium
    }
    description
    primaryOccupations
    dateOfBirth {
      year
      month
      day
    }
    dateOfDeath {
      year
      month
      day
    }
    homeTown
    siteUrl
    favourites
    staffMedia(
      type: MANGA
      page: $page
      perPage: 25
      sort: [START_DATE_DESC]
    ) {
      pageInfo {
        hasNextPage
      }
      edges {
        staffRole
        node {
          id
          idMal
          siteUrl
          title {
            english
            romaji
            native
          }
          coverImage {
            extraLarge
            large
            medium
          }
          startDate {
            year
            month
            day
          }
          endDate {
            year
            month
            day
          }
          countryOfOrigin
          genres
          averageScore
          popularity
        }
      }
    }
  }
}
"""

RELATION_LABELS = {
    "SOURCE": "Source",
    "ADAPTATION": "Adaptation",
    "PREQUEL": "Prequel",
    "SEQUEL": "Sequel",
    "PARENT": "Parent Story",
    "SIDE_STORY": "Side Story",
    "SPIN_OFF": "Spin-off",
    "ALTERNATIVE": "Alternative",
    "CHARACTER": "Character",
    "SUMMARY": "Summary",
    "COMPILATION": "Compilation",
    "CONTAINS": "Contains",
    "OTHER": "Other",
}


def anime(mal_id, *, raise_errors=False):
    """Return cached, normalized AniList enrichment for a MAL anime ID."""
    return _media(
        mal_id,
        media_kind=MediaTypes.ANIME.value,
        query=ANIME_QUERY,
        raise_errors=raise_errors,
    )


def manga(mal_id, *, raise_errors=False):
    """Return cached, normalized AniList enrichment for a MAL manga ID."""
    return _media(
        mal_id,
        media_kind=MediaTypes.MANGA.value,
        query=MANGA_QUERY,
        raise_errors=raise_errors,
    )


def person_page(person_id):
    """Return an AniList staff profile with MAL-backed manga credits."""
    fresh_key = f"anilist:{PERSON_CACHE_VERSION}:person:{person_id}:fresh"
    stale_key = f"anilist:{PERSON_CACHE_VERSION}:person:{person_id}:stale"
    if data := cache.get(fresh_key):
        return data

    stale = cache.get(stale_key)
    try:
        staff = None
        edges = []
        page = 1
        while True:
            response = services.api_request(
                "ANILIST",
                "POST",
                API_URL,
                params={
                    "query": STAFF_QUERY,
                    "variables": {"id": int(person_id), "page": page},
                },
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                },
                timeout=REQUEST_TIMEOUT,
            )
            current = (response.get("data") or {}).get("Staff")
            if not isinstance(current, dict):
                services.raise_not_found_error("anilist", person_id, "person")
            staff = staff or current
            connection = current.get("staffMedia") or {}
            edges.extend(connection.get("edges") or [])
            if not (connection.get("pageInfo") or {}).get("hasNextPage"):
                break
            page += 1

        data = _normalize_staff(staff, edges)
        cache.set(fresh_key, data, FRESH_TTL)
        cache.set(stale_key, data, STALE_TTL)
        return data
    except (
        requests.RequestException,
        services.ProviderAPIError,
        TypeError,
        ValueError,
    ) as error:
        if stale:
            return stale
        if isinstance(error, services.ProviderAPIError):
            raise
        raise services.ProviderAPIError("anilist", error) from error


def _media(mal_id, *, media_kind, query, raise_errors):
    fresh_key = f"anilist:{CACHE_VERSION}:{media_kind}:{mal_id}:fresh"
    stale_key = f"anilist:{CACHE_VERSION}:{media_kind}:{mal_id}:stale"
    failure_key = f"anilist:{CACHE_VERSION}:{media_kind}:{mal_id}:failure"
    if data := cache.get(fresh_key):
        return data

    stale = cache.get(stale_key)
    if cache.get(failure_key):
        if stale:
            return stale
        if raise_errors:
            raise RuntimeError("Cached AniList provider failure")
        return {}

    try:
        response = services.api_request(
            "ANILIST",
            "POST",
            API_URL,
            params={"query": query, "variables": {"malId": int(mal_id)}},
            headers={"Accept": "application/json", "Content-Type": "application/json"},
            timeout=REQUEST_TIMEOUT,
        )
        media = (response.get("data") or {}).get("Media")
        if not isinstance(media, dict):
            raise ValueError(f"AniList returned no matching {media_kind}")
        data = _normalize_media(media, media_kind=media_kind)
        cache.set(fresh_key, data, FRESH_TTL)
        cache.set(stale_key, data, STALE_TTL)
        cache.delete(failure_key)
        return data
    except (
        requests.RequestException,
        AttributeError,
        KeyError,
        TypeError,
        ValueError,
    ) as error:
        logger.warning(
            "AniList enrichment unavailable for MAL %s %s: %s",
            media_kind,
            mal_id,
            error,
        )
        cache.set(failure_key, True, FAILURE_TTL)
        if stale:
            return stale
        if raise_errors:
            raise
        return {}


def _normalize_media(media, *, media_kind=MediaTypes.ANIME.value):
    title = media.get("title") or {}
    cover = media.get("coverImage") or {}
    site_url = media.get("siteUrl") or (
        f"https://anilist.co/{media_kind}/{media['id']}"
    )
    cover_url = cover.get("extraLarge") or cover.get("large") or cover.get("medium")
    score_distribution = ((media.get("stats") or {}).get("scoreDistribution") or [])

    posters = []
    if cover_url:
        posters.append(
            {
                "url": cover_url,
                "thumbnail_url": cover.get("medium") or cover_url,
                "provider_name": "AniList",
                "provider_url": site_url,
            },
        )

    backdrops = []
    if media.get("bannerImage"):
        backdrops.append(
            {
                "url": media["bannerImage"],
                "thumbnail_url": media["bannerImage"],
                "provider_name": "AniList",
                "provider_url": site_url,
            },
        )

    return {
        "anilist_id": str(media["id"]),
        "source_url": site_url,
        "titles": {
            "english": title.get("english"),
            "romaji": title.get("romaji"),
            "native": title.get("native"),
        },
        "display_title": _display_title(title),
        "posters": posters,
        "backdrops": backdrops,
        "backdrop": media.get("bannerImage"),
        "cover_color": cover.get("color"),
        "rating": {
            "value": media.get("averageScore"),
            "vote_count": sum(
                int(bucket.get("amount") or 0)
                for bucket in score_distribution
                if isinstance(bucket, dict)
            ),
            "url": site_url,
        },
        "relations": _relations(media),
        "characters": _characters(media),
        "cast": _cast(media) if media_kind == MediaTypes.ANIME.value else [],
        "creators": _staff(media) if media_kind == MediaTypes.MANGA.value else [],
        "recommendations": (
            _recommendations(media)
            if media_kind == MediaTypes.MANGA.value
            else []
        ),
    }


def _display_title(title):
    return title.get("english") or title.get("romaji") or title.get("native")


def _relations(media):
    relations = []
    for edge in ((media.get("relations") or {}).get("edges") or []):
        if not isinstance(edge, dict):
            continue
        node = edge.get("node") or {}
        mal_id = node.get("idMal")
        node_type = node.get("type")
        if not mal_id or node_type not in {"ANIME", "MANGA"}:
            continue
        title = node.get("title") or {}
        cover = node.get("coverImage") or {}
        media_type = (
            MediaTypes.ANIME.value
            if node_type == "ANIME"
            else MediaTypes.MANGA.value
        )
        relations.append(
            {
                "media_id": str(mal_id),
                "source": Sources.MAL.value,
                "media_type": media_type,
                "title": title.get("romaji") or title.get("native") or title.get("english") or "",
                "display_title": _display_title(title),
                "image": cover.get("extraLarge") or cover.get("large") or cover.get("medium"),
                "release_date": str((node.get("startDate") or {}).get("year") or "") or None,
                "relation": relation_label(edge.get("relationType")),
                "source_url": node.get("siteUrl"),
            },
        )
    return relations


def relation_label(value):
    normalized = str(value or "OTHER").upper()
    return RELATION_LABELS.get(normalized, normalized.replace("_", " ").title())


def _characters(media):
    characters = []
    for edge in ((media.get("characters") or {}).get("edges") or [])[:25]:
        node = edge.get("node") or {}
        name = (node.get("name") or {}).get("full") or (node.get("name") or {}).get("native")
        if not name:
            continue
        image = node.get("image") or {}
        characters.append(
            {
                "person_id": f"character:{node.get('id')}",
                "name": name,
                "role": str(edge.get("role") or "").replace("_", " ").title() or None,
                "image": image.get("large") or image.get("medium"),
            },
        )
    return characters


def _staff(media):
    creators = []
    for edge in ((media.get("staff") or {}).get("edges") or [])[:12]:
        node = edge.get("node") or {}
        name = (node.get("name") or {}).get("full") or (
            node.get("name") or {}
        ).get("native")
        if not name:
            continue
        image = node.get("image") or {}
        person_id = node.get("id")
        creators.append({
            "person_id": str(person_id or ""),
            **({"person_source": "anilist"} if person_id else {}),
            "name": name,
            "role": str(edge.get("role") or "").strip() or None,
            "image": image.get("large") or image.get("medium"),
        })
    return creators


def _normalize_staff(staff, edges):
    name = staff.get("name") or {}
    image = staff.get("image") or {}
    credits = []
    seen = set()
    for edge in edges:
        node = (edge or {}).get("node") or {}
        mal_id = node.get("idMal")
        if not mal_id or mal_id in seen:
            continue
        seen.add(mal_id)
        title = node.get("title") or {}
        cover = node.get("coverImage") or {}
        role = str((edge or {}).get("staffRole") or "").strip() or "Author"
        start_date = _fuzzy_date(node.get("startDate"))
        score = node.get("averageScore")
        credits.append({
            "media_type": MediaTypes.MANGA.value,
            "source": Sources.MAL.value,
            "media_id": str(mal_id),
            "title": title.get("english") or title.get("romaji") or title.get("native") or "",
            "display_title": title.get("english") or title.get("romaji") or title.get("native") or "",
            "image": cover.get("extraLarge") or cover.get("large") or cover.get("medium"),
            "release_date": start_date,
            "year": str((node.get("startDate") or {}).get("year") or "") or None,
            "genres": node.get("genres") or [],
            "languages": [_language_name(node.get("countryOfOrigin"))]
            if node.get("countryOfOrigin")
            else [],
            "roles": [role],
            "credit_roles": [role],
            "vote_average": score / 10 if isinstance(score, (int, float)) else None,
            "vote_count": node.get("popularity"),
            "url": node.get("siteUrl"),
        })

    occupations = [
        str(value).strip()
        for value in staff.get("primaryOccupations") or []
        if str(value).strip()
    ]
    return {
        "source": "anilist",
        "person_id": str(staff.get("id") or ""),
        "name": name.get("full") or name.get("native") or "",
        "image": image.get("large") or image.get("medium"),
        "biography": helpers.plain_text(staff.get("description")),
        "known_for_department": occupations[0] if occupations else "Author",
        "birth_date": _fuzzy_date(staff.get("dateOfBirth")),
        "death_date": _fuzzy_date(staff.get("dateOfDeath")),
        "place_of_birth": staff.get("homeTown"),
        "popularity": staff.get("favourites"),
        "credits": credits,
    }


def _fuzzy_date(value):
    value = value or {}
    year = value.get("year")
    if not year:
        return None
    month = value.get("month")
    day = value.get("day")
    if month and day:
        return f"{int(year):04d}-{int(month):02d}-{int(day):02d}"
    if month:
        return f"{int(year):04d}-{int(month):02d}"
    return str(year)


def _language_name(country_code):
    return {
        "CN": "Chinese",
        "JP": "Japanese",
        "KR": "Korean",
        "TW": "Chinese",
    }.get(str(country_code or "").upper(), str(country_code or "").upper())


def _recommendations(media):
    recommendations = []
    nodes = ((media.get("recommendations") or {}).get("nodes") or [])
    for recommendation in nodes[:12]:
        node = (recommendation or {}).get("mediaRecommendation") or {}
        mal_id = node.get("idMal")
        node_type = node.get("type")
        if not mal_id or node_type not in {"ANIME", "MANGA"}:
            continue
        title = node.get("title") or {}
        cover = node.get("coverImage") or {}
        recommendations.append(
            {
                "media_id": str(mal_id),
                "source": Sources.MAL.value,
                "media_type": (
                    MediaTypes.ANIME.value
                    if node_type == "ANIME"
                    else MediaTypes.MANGA.value
                ),
                "title": (
                    title.get("romaji")
                    or title.get("native")
                    or title.get("english")
                    or ""
                ),
                "display_title": _display_title(title),
                "image": (
                    cover.get("extraLarge")
                    or cover.get("large")
                    or cover.get("medium")
                ),
                "release_date": (
                    str((node.get("startDate") or {}).get("year") or "")
                    or None
                ),
                "source_url": node.get("siteUrl"),
            },
        )
    return recommendations


def _cast(media):
    cast = []
    for edge in ((media.get("characters") or {}).get("edges") or [])[:25]:
        character = edge.get("node") or {}
        character_name = (character.get("name") or {}).get("full") or (
            character.get("name") or {}
        ).get("native")
        voice_actor = _preferred_voice_actor(edge.get("voiceActors") or [])
        if not character_name or not voice_actor:
            continue
        name = (voice_actor.get("name") or {}).get("full") or (
            voice_actor.get("name") or {}
        ).get("native")
        if not name:
            continue
        image = voice_actor.get("image") or {}
        cast.append(
            {
                "person_id": f"voice:{voice_actor.get('id')}:{character.get('id')}",
                "name": name,
                "character": character_name,
                "image": image.get("large") or image.get("medium"),
            },
        )
    return cast


def _preferred_voice_actor(voice_actors):
    if not voice_actors:
        return None
    return next(
        (
            actor
            for actor in voice_actors
            if str(actor.get("languageV2") or "").lower() == "japanese"
        ),
        voice_actors[0],
    )
