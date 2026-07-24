"""Strict, API-key-only Google Books volume enrichment."""

import re
from decimal import Decimal, InvalidOperation
from urllib.parse import urlsplit, urlunsplit

import requests
from bs4 import BeautifulSoup
from django.conf import settings
from django.core.cache import cache
from django_redis.exceptions import ConnectionInterrupted
from redis.exceptions import RedisError

from app.providers import services

BASE_URL = "https://www.googleapis.com/books/v1/volumes"
CACHE_VERSION = "v1"
FIELDS = (
    "items(id,volumeInfo(title,subtitle,authors,publisher,publishedDate,"
    "description,industryIdentifiers,pageCount,categories,averageRating,"
    "ratingsCount,maturityRating,imageLinks,language,canonicalVolumeLink),"
    "saleInfo(country,saleability,retailPrice))"
)
IMAGE_KEYS = ("extraLarge", "large", "medium", "small", "thumbnail", "smallThumbnail")
CANONICAL_HOSTS = {"books.google.com"}
COVER_HOSTS = {
    "books.google.com",
    "books.googleusercontent.com",
    "lh3.googleusercontent.com",
}


def isbn13_identity(value):
    """Return the checksum-valid ISBN-13 identity for an ISBN-10/13."""
    normalized = re.sub(r"[^0-9Xx]", "", str(value or ""))
    if len(normalized) == 10:
        if not _valid_isbn10(normalized):
            return None
        body = f"978{normalized[:9]}"
        return f"{body}{_isbn13_check_digit(body)}"
    if len(normalized) == 13 and _valid_isbn13(normalized):
        return normalized
    return None


def edition_identity(isbns):
    """Return one unambiguous ISBN-13 identity from provider edition ISBNs."""
    values = [isbn for isbn in isbns or [] if _clean_text(isbn)]
    identities = {isbn13_identity(isbn) for isbn in values}
    if None in identities:
        return None
    return identities.pop() if len(identities) == 1 else None


def lookup_volume(isbns):
    """Return one exact normalized Google Books volume, or None."""
    if not getattr(settings, "GOOGLE_BOOKS_API_KEY", ""):
        return None
    matched_isbn = edition_identity(isbns)
    if matched_isbn is None:
        return None

    cache_key = f"google-books:{CACHE_VERSION}:{matched_isbn}"
    try:
        cached = cache.get(cache_key)
    except (ConnectionInterrupted, RedisError, ConnectionError, OSError):
        cached = None
    if isinstance(cached, dict):
        return cached

    try:
        response = services.session.get(
            BASE_URL,
            params={
                "q": f"isbn:{matched_isbn}",
                "maxResults": 10,
                "projection": "full",
                "fields": FIELDS,
                "key": settings.GOOGLE_BOOKS_API_KEY,
            },
            timeout=settings.REQUEST_TIMEOUT,
        )
        response.raise_for_status()
        payload = response.json()
    except (requests.RequestException, ValueError) as error:
        raise services.ProviderAPIError("google books", error) from error

    normalized = _exact_volume(payload, matched_isbn)
    ttl = _shared_cache_ttl(response.headers)
    if normalized is not None and ttl is not None:
        try:
            cache.set(cache_key, normalized, ttl)
        except (ConnectionInterrupted, RedisError, ConnectionError, OSError):
            pass
    return normalized


def _valid_isbn10(value):
    if not re.fullmatch(r"\d{9}[\dXx]", value):
        return False
    digits = [int(character) for character in value[:9]]
    digits.append(10 if value[-1].upper() == "X" else int(value[-1]))
    return sum((10 - index) * digit for index, digit in enumerate(digits)) % 11 == 0


def _isbn13_check_digit(body):
    total = sum(int(character) * (1 if index % 2 == 0 else 3) for index, character in enumerate(body))
    return str((10 - total % 10) % 10)


def _valid_isbn13(value):
    return bool(re.fullmatch(r"\d{13}", value)) and value[-1] == _isbn13_check_digit(value[:12])


def _exact_volume(payload, matched_isbn):
    if not isinstance(payload, dict):
        return None
    items = payload.get("items") or []
    if not isinstance(items, list):
        return None
    matches = []
    for item in items:
        volume_info = item.get("volumeInfo") if isinstance(item, dict) else None
        if not isinstance(volume_info, dict):
            continue
        raw_identifiers = volume_info.get("industryIdentifiers") or []
        if not isinstance(raw_identifiers, list) or any(
            isinstance(entry, dict) and entry.get("type") == "OTHER"
            for entry in raw_identifiers
        ):
            continue
        identifiers = [
            entry
            for entry in raw_identifiers
            if isinstance(entry, dict) and entry.get("type") in {"ISBN_10", "ISBN_13"}
        ]
        identities = [isbn13_identity(entry.get("identifier")) for entry in identifiers]
        if not identities or any(identity is None for identity in identities):
            continue
        if set(identities) != {matched_isbn}:
            continue
        normalized = _normalize_volume(item, volume_info, matched_isbn)
        if normalized is not None:
            matches.append(normalized)
    return matches[0] if len(matches) == 1 else None


def _normalize_volume(item, volume_info, matched_isbn):
    canonical_url = _trusted_url(volume_info.get("canonicalVolumeLink"), CANONICAL_HOSTS)
    volume_id = _clean_text(item.get("id"))
    if not canonical_url or not volume_id:
        return None

    normalized = {
        "matched_isbn": matched_isbn,
        "volume_id": volume_id,
        "canonical_url": canonical_url,
    }
    for source_key, target_key in (
        ("title", "title"),
        ("subtitle", "subtitle"),
        ("publisher", "publisher"),
    ):
        if value := _clean_text(volume_info.get(source_key)):
            normalized[target_key] = value

    if description := _clean_description(volume_info.get("description")):
        normalized["description"] = description
    if authors := _clean_list(volume_info.get("authors")):
        normalized["authors"] = authors
    if categories := _clean_list(volume_info.get("categories")):
        normalized["categories"] = categories

    published_date = _clean_text(volume_info.get("publishedDate"))
    if published_date and re.fullmatch(r"\d{4}(?:-\d{2}(?:-\d{2})?)?", published_date):
        normalized["published_date"] = published_date

    try:
        page_count = int(volume_info.get("pageCount"))
    except (TypeError, ValueError):
        page_count = 0
    if page_count > 0:
        normalized["page_count"] = page_count

    language = _clean_text(volume_info.get("language"))
    if language and re.fullmatch(r"[A-Za-z]{2,3}", language):
        normalized["language"] = language.lower()

    maturity = _clean_text(volume_info.get("maturityRating"))
    if maturity in {"MATURE", "NOT_MATURE"}:
        normalized["maturity_rating"] = maturity

    image_links = volume_info.get("imageLinks") or {}
    if isinstance(image_links, dict):
        for key in IMAGE_KEYS:
            cover_url = _trusted_url(image_links.get(key), COVER_HOSTS)
            if cover_url:
                normalized["cover_url"] = cover_url
                break

    rating = _rating(volume_info)
    if rating:
        normalized["rating"] = rating
    price = _price(item.get("saleInfo"))
    if price:
        normalized["price"] = price
    return normalized


def _clean_text(value):
    text = str(value or "").strip()
    return text or None


def _clean_list(values):
    if not isinstance(values, list):
        return []
    return list(dict.fromkeys(text for value in values if (text := _clean_text(value))))


def _clean_description(value):
    text = _clean_text(value)
    return BeautifulSoup(text, "html.parser").get_text(" ", strip=True) if text else None


def _trusted_url(value, hosts):
    text = _clean_text(value)
    if not text:
        return None
    try:
        parts = urlsplit(text)
        hostname = parts.hostname
        port = parts.port
    except ValueError:
        return None
    if (
        parts.scheme not in {"http", "https"}
        or parts.username
        or parts.password
        or port is not None
    ):
        return None
    if hostname not in hosts:
        return None
    return urlunsplit(("https", parts.netloc, parts.path, parts.query, ""))


def _compact_decimal(value):
    text = format(value, "f").rstrip("0").rstrip(".")
    return text or "0"


def _rating(volume_info):
    try:
        value = Decimal(str(volume_info.get("averageRating")))
    except (InvalidOperation, TypeError, ValueError):
        return None
    if not value.is_finite() or not Decimal("1") <= value <= Decimal("5"):
        return None
    try:
        count = int(volume_info.get("ratingsCount"))
    except (TypeError, ValueError):
        count = None
    return {
        "value": _compact_decimal(value),
        "count": count if count is not None and count >= 0 else None,
    }


def _price(sale_info):
    if not isinstance(sale_info, dict) or sale_info.get("saleability") == "NOT_FOR_SALE":
        return None
    retail_price = sale_info.get("retailPrice")
    if not isinstance(retail_price, dict):
        return None
    try:
        amount = Decimal(str(retail_price.get("amount")))
    except (InvalidOperation, TypeError, ValueError):
        return None
    currency = _clean_text(retail_price.get("currencyCode"))
    country = _clean_text(sale_info.get("country"))
    if (
        not amount.is_finite()
        or amount < 0
        or not currency
        or not re.fullmatch(r"[A-Za-z]{3}", currency)
        or not country
        or not re.fullmatch(r"[A-Za-z]{2}", country)
    ):
        return None
    return {
        "amount": _compact_decimal(amount),
        "currency": currency.upper(),
        "country": country.upper(),
    }


def _shared_cache_ttl(headers):
    cache_control = str((headers or {}).get("Cache-Control") or "")
    directives = [directive.strip().lower() for directive in cache_control.split(",")]
    if not directives or any(
        directive in {"private", "no-cache", "no-store"} for directive in directives
    ):
        return None
    for name in ("s-maxage", "max-age"):
        prefix = f"{name}="
        for directive in directives:
            if directive.startswith(prefix):
                try:
                    ttl = int(directive[len(prefix) :].strip('"'))
                except ValueError:
                    return None
                return ttl if ttl > 0 else None
    return None
