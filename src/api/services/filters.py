import logging
from datetime import date
from decimal import Decimal, InvalidOperation

from django.apps import apps
from django.db import models
from django.db.models import Avg, Case, OuterRef, Q, Subquery, Value, When
from django.db.models.functions import Lower
from django.utils import timezone
from django.utils.dateparse import parse_date
from requests import RequestException

from app import exposure
from app.models import Item, ItemFilterFacet, MediaTypes, Status

logger = logging.getLogger(__name__)

RATING_SORTS = {
    "letterboxd_rating": "letterboxd_rating",
    "imdb_rating": "imdb_rating",
    "rotten_tomatoes_rating": "rotten_tomatoes_rating",
}

API_SORTS = [
    {"value": "title", "label": "Title"},
    {"value": "release_date", "label": "Release Date"},
    {"value": "your_rating", "label": "Your Rating"},
    {"value": "average_rating", "label": "Average Rating"},
    {"value": "letterboxd_rating", "label": "Letterboxd Rating"},
    {"value": "imdb_rating", "label": "IMDb Rating"},
    {"value": "rotten_tomatoes_rating", "label": "Rotten Tomatoes"},
]

DESC_SORTS = {
    "release_date",
    "your_rating",
    "average_rating",
    "letterboxd_rating",
    "imdb_rating",
    "rotten_tomatoes_rating",
    "consumed_at",
    "date_added",
}

METADATA_SORTS = {"release_date"}
SHORT_FILM_MINUTES = 40


def values(params, key):
    """Return non-empty repeated query values."""
    if not hasattr(params, "getlist"):
        value = params.get(key)
        return [value] if value not in (None, "") else []
    return [value for value in params.getlist(key) if value not in (None, "")]


def bool_param(params, key):
    """Return a boolean query parameter when present."""
    value = params.get(key)
    if value is None:
        return None
    return str(value).lower() in {"1", "true", "yes", "on"}


def decimal_param(params, key):
    """Return a decimal query parameter when valid."""
    value = params.get(key)
    if value in (None, ""):
        return None
    try:
        return Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return None


def int_param(params, key):
    """Return an integer query parameter when valid."""
    value = params.get(key)
    if value in (None, ""):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def date_param(params, key):
    """Return an ISO date query parameter when valid."""
    value = params.get(key)
    if not value:
        return None
    return parse_date(value)


def update_item_filter_metadata(item, metadata, ratings=None):
    """Cache provider fields needed for fast collection filtering."""
    if not item or not metadata:
        return

    release_date = _release_date(metadata)
    release_year = _release_year(metadata, release_date)
    updates = {
        "release_date": release_date,
        "release_year": release_year,
        "runtime_minutes": _runtime_minutes(metadata),
        "filter_metadata_updated_at": timezone.now(),
    }
    for source, field in {
        "letterboxd": "letterboxd_rating",
        "imdb": "imdb_rating",
        "tomatoes": "rotten_tomatoes_rating",
    }.items():
        rating = (ratings or {}).get(source)
        if rating:
            updates[field] = _rating_decimal(rating.get("value") or rating.get("score"))

    changed = []
    for field, value in updates.items():
        if getattr(item, field) != value:
            setattr(item, field, value)
            changed.append(field)
    if changed:
        item.save(update_fields=changed)

    _replace_facets(item, ItemFilterFacet.FacetType.GENRE, _metadata_list(metadata, "genres"))
    _replace_facets(
        item,
        ItemFilterFacet.FacetType.LANGUAGE,
        _metadata_list(metadata, "languages"),
    )


def update_item_external_ratings(
    *,
    source,
    media_type,
    media_id,
    ratings,
    season_number=None,
    episode_number=None,
):
    """Cache external ratings for an already materialized exact item."""
    if not ratings:
        return
    item = Item.objects.filter(
        source=source,
        media_type=media_type,
        media_id=media_id,
        season_number=season_number,
        episode_number=episode_number,
    ).first()
    if item is None:
        return
    updates = {"filter_metadata_updated_at": timezone.now()}
    for source_key, field in {
        "letterboxd": "letterboxd_rating",
        "imdb": "imdb_rating",
        "tomatoes": "rotten_tomatoes_rating",
    }.items():
        rating = ratings.get(source_key)
        if rating:
            updates[field] = _rating_decimal(rating.get("value") or rating.get("score"))

    changed = []
    for field, value in updates.items():
        if getattr(item, field) != value:
            setattr(item, field, value)
            changed.append(field)
    if changed:
        item.save(update_fields=changed)


def apply_item_filters(queryset, params, *, item_path="item__"):
    """Apply shared Item-backed filters to a queryset."""
    query = params.get("q", "").strip()
    if query:
        queryset = queryset.filter(**{f"{item_path}title__icontains": query})

    media_types = values(params, "media_type")
    if media_types:
        queryset = queryset.filter(**{f"{item_path}media_type__in": media_types})

    year_values = values(params, "year")
    if year_values:
        queryset = queryset.filter(**{f"{item_path}release_year__in": year_values})

    year_min = int_param(params, "year_min")
    if year_min is not None:
        queryset = queryset.filter(**{f"{item_path}release_year__gte": year_min})

    year_max = int_param(params, "year_max")
    if year_max is not None:
        queryset = queryset.filter(**{f"{item_path}release_year__lte": year_max})

    release_status = params.get("release_status")
    if release_status == "released":
        queryset = queryset.filter(**{f"{item_path}release_date__lte": timezone.localdate()})
    elif release_status == "unreleased":
        queryset = queryset.filter(**{f"{item_path}release_date__gt": timezone.localdate()})

    length = params.get("length")
    if length == "feature":
        queryset = queryset.filter(**{f"{item_path}runtime_minutes__gte": SHORT_FILM_MINUTES})
    elif length == "short":
        queryset = queryset.filter(**{f"{item_path}runtime_minutes__lt": SHORT_FILM_MINUTES})

    queryset = _apply_facet_filter(queryset, params, item_path, "genre")
    queryset = _apply_facet_filter(queryset, params, item_path, "language")
    queryset = _apply_facet_exclude(queryset, params, item_path, "genre")
    queryset = _apply_facet_exclude(queryset, params, item_path, "language")
    return queryset


def ensure_filter_metadata(queryset, params, *, item_path="item__", force=False, limit=1000):
    """Populate missing Item filter metadata before DB filtering/sorting."""
    needed_facets = set()
    needs_year = force or bool(values(params, "year")) or params.get("year_min") or params.get("year_max")
    needs_release_date = (
        force
        or (params.get("sort") or params.get("ordering")) in METADATA_SORTS
        or params.get("release_status") in {"released", "unreleased"}
    )
    needs_runtime = force or params.get("length") in {"feature", "short"}
    if force or values(params, "genre") or values(params, "exclude_genre"):
        needed_facets.add(ItemFilterFacet.FacetType.GENRE)
    if force or values(params, "language") or values(params, "exclude_language"):
        needed_facets.add(ItemFilterFacet.FacetType.LANGUAGE)
    if not (needs_year or needs_release_date or needs_runtime or needed_facets):
        return

    from app.providers import services as provider_services

    item_ids = queryset.values_list(f"{item_path}id", flat=True)
    candidates = Item.objects.filter(id__in=item_ids).prefetch_related("filter_facets")[:limit]
    for item in candidates:
        facets = {facet.facet_type for facet in item.filter_facets.all()}
        has_needed_values = (
            (not needs_year or item.release_year is not None)
            and (not needs_release_date or item.release_date is not None)
            and (not needs_runtime or item.runtime_minutes is not None)
            and needed_facets.issubset(facets)
        )
        if has_needed_values:
            continue
        try:
            metadata = provider_services.get_media_metadata(
                item.media_type,
                item.media_id,
                item.source,
                season_numbers=[item.season_number] if item.season_number else None,
                episode_number=item.episode_number,
            )
        except (
            provider_services.ProviderAPIError,
            RequestException,
            NotImplementedError,
            TypeError,
            ValueError,
        ) as error:
            logger.debug(
                "Skipping filter metadata backfill for item %s: %s",
                item.id,
                error,
            )
            continue
        update_item_filter_metadata(item, metadata)


def apply_rating_range(queryset, params, field):
    """Apply rating_min/rating_max to a numeric field."""
    rating_min = decimal_param(params, "rating_min")
    if rating_min is not None:
        queryset = queryset.filter(**{f"{field}__gte": rating_min})
    rating_max = decimal_param(params, "rating_max")
    if rating_max is not None:
        queryset = queryset.filter(**{f"{field}__lte": rating_max})
    return queryset


def apply_watched_range(queryset, params, field):
    """Apply watched_from/watched_to to a DateTimeField."""
    watched_from = date_param(params, "watched_from")
    if watched_from:
        queryset = queryset.filter(**{f"{field}__date__gte": watched_from})
    watched_to = date_param(params, "watched_to")
    if watched_to:
        queryset = queryset.filter(**{f"{field}__date__lte": watched_to})
    return queryset


def apply_user_status_filter(queryset, user, status, *, item_id_field="item_id"):
    """Filter an Item-bearing queryset by the viewer's tracking status."""
    if not status or status == "All":
        return queryset
    tracked_only = str(status).lower() == "tracked"

    status_query = Q()
    for media_type in exposure.user_owned_media_types():
        model = apps.get_model("app", media_type)
        media_queryset = model.objects.filter(user=user)
        if tracked_only:
            media_queryset = media_queryset.exclude(status=Status.PLANNING.value)
        else:
            media_queryset = media_queryset.filter(status=status)
        status_query |= Q(
            **{
                "item__media_type": media_type,
                f"{item_id_field}__in": media_queryset.values("item_id"),
            },
        )
    return queryset.filter(status_query)


def annotate_user_rating(queryset, user, *, item_id_field="item_id", annotation="user_rating"):
    """Annotate mixed Item querysets with the current user's tracking score."""
    cases = []
    for media_type in exposure.user_owned_media_types():
        model = apps.get_model("app", media_type)
        cases.append(
            When(
                item__media_type=media_type,
                then=Subquery(
                    model.objects.filter(
                        user=user,
                        item_id=OuterRef(item_id_field),
                    ).values("score")[:1],
                ),
            ),
        )
    return queryset.annotate(
        **{
            annotation: Case(
                *cases,
                default=Value(None),
                output_field=models.DecimalField(max_digits=3, decimal_places=1),
            ),
        },
    )


def order_queryset(
    queryset,
    params,
    *,
    item_path="item__",
    your_rating_field=None,
    default_sort="title",
    extra_sorts=None,
):
    """Apply shared sort options with stable null handling."""
    sort = params.get("sort") or params.get("ordering") or default_sort
    direction = params.get("direction")
    if direction not in {"asc", "desc"}:
        direction = "desc" if sort in DESC_SORTS else "asc"
    descending = direction == "desc"

    sort_fields = {
        "title": f"{item_path}title",
        "release_date": f"{item_path}release_date",
        **{key: f"{item_path}{field}" for key, field in RATING_SORTS.items()},
        **(extra_sorts or {}),
    }

    if sort == "average_rating":
        queryset = queryset.annotate(
            average_rating=Avg(
                f"{item_path}diaryentry__rating",
                filter=~Q(**{f"{item_path}diaryentry__visibility": "private"}),
            ),
        )
        return _order_by_field(queryset, "average_rating", descending, item_path)

    if sort == "your_rating" and your_rating_field:
        return _order_by_field(queryset, your_rating_field, descending, item_path)

    field = sort_fields.get(sort)
    if field is None:
        field = sort_fields[default_sort]

    if sort == "title":
        title_order = Lower(field).desc() if descending else Lower(field).asc()
        return queryset.order_by(title_order, "-id" if descending else "id")

    return _order_by_field(queryset, field, descending, item_path)


def filter_options_for_items(queryset, *, item_path="item__"):
    """Return available facet values for an Item-backed queryset."""
    item_ids = queryset.values_list(f"{item_path}id", flat=True)
    facets = ItemFilterFacet.objects.filter(item_id__in=item_ids)
    return {
        "sorts": API_SORTS,
        "genres": _facet_values(facets, ItemFilterFacet.FacetType.GENRE),
        "languages": _facet_values(facets, ItemFilterFacet.FacetType.LANGUAGE),
        "years": list(
            Item.objects.filter(id__in=item_ids, release_year__isnull=False)
            .order_by("-release_year")
            .values_list("release_year", flat=True)
            .distinct(),
        ),
    }


def apply_person_credit_filters(credit_list, params):
    """Apply in-memory filters to provider person credits."""
    active_keys = {
        "media_type",
        "year",
        "year_min",
        "year_max",
        "release_status",
        "length",
        "genre",
        "language",
        "exclude_genre",
        "exclude_language",
        "sort",
        "ordering",
        "direction",
    }
    if not any(values(params, key) for key in active_keys):
        return credit_list

    media_types = set(values(params, "media_type"))
    years = set(values(params, "year"))
    year_min = int_param(params, "year_min")
    year_max = int_param(params, "year_max")
    release_status = params.get("release_status")
    length = params.get("length")
    genres = set(values(params, "genre"))
    languages = set(values(params, "language"))
    excluded_genres = set(values(params, "exclude_genre"))
    excluded_languages = set(values(params, "exclude_language"))

    filtered = [
        credit
        for credit in credit_list
        if _person_credit_matches(
            credit,
            media_types,
            years,
            year_min,
            year_max,
            release_status,
            None,
            genres,
            languages,
            excluded_genres,
            excluded_languages,
        )
    ]
    if length in {"feature", "short"}:
        filtered = [
            credit
            for credit in _credits_with_cached_runtime(filtered)
            if _person_credit_matches(
                credit,
                media_types,
                years,
                year_min,
                year_max,
                release_status,
                length,
                genres,
                languages,
                excluded_genres,
                excluded_languages,
            )
        ]

    sort = params.get("sort") or "average_rating"
    direction = params.get("direction")
    if direction not in {"asc", "desc"}:
        direction = "desc" if sort in DESC_SORTS else "asc"
    descending = direction == "desc"

    if sort == "release_date":
        def key(credit):
            release_date = _credit_release_date(credit)
            ordinal = release_date.toordinal() if release_date else 0
            return (release_date is None, -ordinal if descending else ordinal)
    elif sort in {"average_rating", "your_rating"}:
        def key(credit):
            rating = _credit_number(credit, "vote_average")
            value = float(rating or 0)
            return (rating is None, -value if descending else value)
    else:
        return sorted(filtered, key=lambda credit: (credit.get("title") or "").lower(), reverse=descending)
    return sorted(filtered, key=key)


def _person_credit_matches(  # noqa: C901, PLR0911
    credit,
    media_types,
    years,
    year_min,
    year_max,
    release_status=None,
    length=None,
    genres=None,
    languages=None,
    excluded_genres=None,
    excluded_languages=None,
):
    year = _credit_year(credit)
    if media_types and credit.get("media_type") not in media_types:
        return False
    if years and str(year) not in years:
        return False
    if year_min is not None and (year is None or year < year_min):
        return False
    if year_max is not None and (year is None or year > year_max):
        return False
    if genres and genres.isdisjoint(set(credit.get("genres") or [])):
        return False
    if languages and languages.isdisjoint(set(credit.get("languages") or [])):
        return False
    if excluded_genres and not excluded_genres.isdisjoint(set(credit.get("genres") or [])):
        return False
    if excluded_languages and not excluded_languages.isdisjoint(set(credit.get("languages") or [])):
        return False

    release_date = _credit_release_date(credit)
    today = timezone.localdate()
    if release_status == "released" and (release_date is None or release_date > today):
        return False
    if release_status == "unreleased" and (release_date is None or release_date <= today):
        return False

    runtime = _credit_runtime_minutes(credit)
    if length == "feature":
        return credit.get("media_type") == MediaTypes.MOVIE.value and runtime is not None and runtime >= SHORT_FILM_MINUTES
    if length == "short":
        return credit.get("media_type") == MediaTypes.MOVIE.value and runtime is not None and runtime < SHORT_FILM_MINUTES
    return True


def _replace_facets(item, facet_type, facet_values):
    wanted = {value.strip() for value in facet_values if value and value.strip()}
    existing = set(
        ItemFilterFacet.objects.filter(item=item, facet_type=facet_type).values_list(
            "value",
            flat=True,
        ),
    )
    if existing == wanted:
        return
    ItemFilterFacet.objects.filter(item=item, facet_type=facet_type).delete()
    ItemFilterFacet.objects.bulk_create(
        [
            ItemFilterFacet(item=item, facet_type=facet_type, value=value)
            for value in sorted(wanted)
        ],
        ignore_conflicts=True,
    )


def _metadata_list(metadata, key):
    details = metadata.get("details") or {}
    values_list = metadata.get(key) or details.get(key) or []
    normalized = []
    for raw_value in values_list or []:
        value = raw_value
        if isinstance(raw_value, dict):
            value = raw_value.get("name") or raw_value.get("english_name") or raw_value.get("tag")
        if value:
            normalized.append(str(value))
    return normalized


def _release_date(metadata):
    details = metadata.get("details") or {}
    value = (
        metadata.get("release_date")
        or metadata.get("first_air_date")
        or metadata.get("start_date")
        or metadata.get("end_date")
        or metadata.get("first_release_date")
        or details.get("release_date")
        or details.get("first_release_date")
        or details.get("first_air_date")
        or details.get("publish_date")
        or details.get("published_date")
    )
    if isinstance(value, date):
        return value
    if not value:
        return None
    value = str(value)
    if len(value) == 4 and value.isdigit():
        return date(int(value), 1, 1)
    if len(value) == 7:
        value = f"{value}-01"
    return parse_date(value)


def _release_year(metadata, release_date):
    if release_date:
        return release_date.year
    for value in (metadata.get("year"), (metadata.get("details") or {}).get("year")):
        if value:
            try:
                return int(value)
            except (TypeError, ValueError):
                return None
    return None


def _rating_decimal(value):
    if value in (None, ""):
        return None
    try:
        return Decimal(str(value).replace("%", ""))
    except (InvalidOperation, TypeError, ValueError):
        return None


def _runtime_minutes(metadata):
    details = metadata.get("details") or {}
    return _runtime_value_minutes(metadata.get("runtime") or details.get("runtime"))


def _runtime_value_minutes(value):
    if value in (None, ""):
        return None
    if isinstance(value, int | float):
        return int(value) or None
    text = str(value).strip().lower()
    total = 0
    for part in text.split():
        number = part[:-1]
        if not number.isdigit():
            continue
        if part.endswith("h"):
            total += int(number) * 60
        elif part.endswith("m"):
            total += int(number)
    if total:
        return total
    try:
        return int(text)
    except ValueError:
        return None


def _apply_facet_filter(queryset, params, item_path, facet_type):
    facet_values = values(params, facet_type)
    if not facet_values:
        return queryset
    path = f"{item_path}filter_facets__"
    return queryset.filter(
        **{
            f"{path}facet_type": facet_type,
            f"{path}value__in": facet_values,
        },
    ).distinct()


def _apply_facet_exclude(queryset, params, item_path, facet_type):
    facet_values = values(params, f"exclude_{facet_type}")
    if not facet_values:
        return queryset
    path = f"{item_path}filter_facets__"
    return queryset.exclude(
        **{
            f"{path}facet_type": facet_type,
            f"{path}value__in": facet_values,
        },
    ).distinct()


def _order_by_field(queryset, field, descending, item_path):
    order = (
        models.F(field).desc(nulls_last=True)
        if descending
        else models.F(field).asc(nulls_last=True)
    )
    return queryset.order_by(order, Lower(f"{item_path}title"))


def _facet_values(facets, facet_type):
    return [
        {"value": value, "label": value}
        for value in facets.filter(facet_type=facet_type)
        .order_by("value")
        .values_list("value", flat=True)
        .distinct()
    ]


def _credit_year(credit):
    year = credit.get("year") or (_credit_date_text(credit) or "")[:4]
    try:
        return int(year)
    except (TypeError, ValueError):
        return None


def _credit_release_date(credit):
    value = _credit_date_text(credit)
    if isinstance(value, date):
        return value
    if value:
        value = str(value)
        if len(value) == 4 and value.isdigit():
            return date(int(value), 1, 1)
        parsed = parse_date(value)
        if parsed:
            return parsed
    year = credit.get("year")
    if year:
        try:
            return date(int(year), 1, 1)
        except (TypeError, ValueError):
            return None
    return None


def _credit_date_text(credit):
    return credit.get("release_date") or credit.get("first_air_date") or credit.get("publish_date")


def _credits_with_cached_runtime(credit_list):
    missing = [
        credit
        for credit in credit_list
        if credit.get("media_type") == MediaTypes.MOVIE.value and _credit_runtime_minutes(credit) is None
    ]
    if not missing:
        return credit_list

    ids = [str(credit.get("media_id") or "") for credit in missing]
    sources = {credit.get("source") for credit in missing if credit.get("source")}
    cached = {
        (item.source, item.media_id): item.runtime_minutes
        for item in Item.objects.filter(
            source__in=sources,
            media_type=MediaTypes.MOVIE.value,
            media_id__in=ids,
            runtime_minutes__isnull=False,
        )
    }
    return [
        {**credit, "runtime_minutes": cached[(credit.get("source"), str(credit.get("media_id") or ""))]}
        if (credit.get("source"), str(credit.get("media_id") or "")) in cached
        else credit
        for credit in credit_list
    ]


def _credit_runtime_minutes(credit):
    runtime = credit.get("runtime_minutes")
    if runtime is not None:
        try:
            return int(runtime)
        except (TypeError, ValueError):
            return None
    return _runtime_value_minutes(credit.get("runtime"))


def _credit_number(credit, field):
    try:
        return float(credit.get(field))
    except (TypeError, ValueError):
        return None
