from unittest.mock import patch

from django.core.cache import cache
from django.test import TestCase

from app.models import Sources
from app.providers import (
    anilist,
    hardcover,
    mal,
    mangaupdates,
    musicbrainz,
    openlibrary,
    services,
    tmdb,
)


class ProviderPeopleSearchTests(TestCase):
    def setUp(self):
        cache.clear()

    @patch("app.providers.tmdb.services.api_request")
    def test_tmdb_people_search(self, request):
        request.return_value = {
            "results": [{
                "id": 819,
                "name": "Edward Norton",
                "profile_path": "/edward.jpg",
                "known_for_department": "Acting",
            }],
        }

        result = tmdb.search_people("Edward", limit=5, timeout=3)

        self.assertEqual(result[0]["person_id"], "819")
        self.assertEqual(
            result[0]["profile_url"],
            "https://image.tmdb.org/t/p/w500/edward.jpg",
        )
        self.assertEqual(
            request.call_args.kwargs["params"]["query"],
            "Edward",
        )
        self.assertIs(
            request.call_args.kwargs["request_session"],
            services.person_search_session,
        )

    @patch("app.providers.hardcover.services.api_request")
    def test_hardcover_people_search(self, request):
        request.return_value = {
            "data": {
                "search": {
                    "results": {
                        "hits": [{
                            "document": {
                                "id": 42,
                                "name": "Octavia Butler",
                                "image": {
                                    "url": "https://example.com/octavia.jpg",
                                },
                            },
                        }],
                    },
                },
            },
        }

        result = hardcover.search_people("Octavia", limit=5, timeout=3)

        self.assertEqual(
            result,
            [{
                "source": Sources.HARDCOVER.value,
                "person_id": "42",
                "name": "Octavia Butler",
                "profile_url": "https://example.com/octavia.jpg",
                "known_for_department": "Author",
            }],
        )
        self.assertEqual(
            request.call_args.kwargs["params"]["variables"]["query"],
            "Octavia",
        )

    @patch("app.providers.openlibrary.services.api_request")
    def test_openlibrary_people_search(self, request):
        request.return_value = {
            "docs": [{
                "key": "/authors/OL1A",
                "name": "Ursula K. Le Guin",
                "photos": [123],
            }],
        }

        result = openlibrary.search_people("Le Guin", limit=5, timeout=3)

        self.assertEqual(result[0]["person_id"], "OL1A")
        self.assertEqual(
            result[0]["profile_url"],
            "https://covers.openlibrary.org/a/id/123-M.jpg",
        )

    @patch("app.providers.musicbrainz._musicbrainz_request")
    def test_musicbrainz_people_search_only_requests_people(self, request):
        request.return_value = {
            "artists": [{
                "id": "artist-id",
                "name": "Nina Simone",
                "type": "Person",
            }],
        }

        result = musicbrainz.search_people("Nina Simone", limit=5, timeout=3)

        self.assertEqual(result[0]["person_id"], "artist-id")
        self.assertIn(
            "type:person",
            request.call_args.args[1]["query"],
        )
        self.assertEqual(request.call_args.kwargs["max_attempts"], 1)
        self.assertFalse(request.call_args.kwargs["retry_rate_limits"])

    @patch("app.providers.musicbrainz.services.api_request")
    def test_musicbrainz_request_threads_disabled_rate_limit_retries(
        self,
        request,
    ):
        request.return_value = {"artists": []}

        musicbrainz._musicbrainz_request(
            "artist",
            {"query": "artist:Ada AND type:person"},
            max_attempts=1,
            retry_rate_limits=False,
        )

        self.assertFalse(request.call_args.kwargs["retry_rate_limits"])

    @patch("app.providers.mal.services.api_request")
    def test_mal_people_search(self, request):
        request.return_value = {
            "data": [{
                "mal_id": 1,
                "name": "Hayao Miyazaki",
                "images": {
                    "jpg": {"image_url": "https://example.com/miyazaki.jpg"},
                },
            }],
        }

        result = mal.search_people("Miyazaki", limit=5, timeout=3)

        self.assertEqual(result[0]["person_id"], "1")
        self.assertEqual(
            result[0]["profile_url"],
            "https://example.com/miyazaki.jpg",
        )

    @patch("app.providers.mangaupdates.services.api_request")
    def test_mangaupdates_people_search(self, request):
        request.return_value = {
            "results": [{
                "record": {
                    "author_id": 8,
                    "name": "Naoki Urasawa",
                    "type": "Author",
                    "image": {
                        "url": {
                            "original": "https://example.com/urasawa.jpg",
                        },
                    },
                },
            }],
        }

        result = mangaupdates.search_people(
            "Urasawa",
            limit=5,
            timeout=3,
        )

        self.assertEqual(result[0]["person_id"], "8")
        self.assertEqual(
            result[0]["profile_url"],
            "https://example.com/urasawa.jpg",
        )

    @patch("app.providers.anilist.services.api_request")
    def test_anilist_people_search(self, request):
        request.return_value = {
            "data": {
                "Page": {
                    "staff": [{
                        "id": 9,
                        "name": {"full": "Yoko Kanno"},
                        "image": {"large": "https://example.com/kanno.jpg"},
                        "primaryOccupations": ["Composer"],
                    }],
                },
            },
        }

        result = anilist.search_people("Yoko Kanno", limit=5, timeout=3)

        self.assertEqual(result[0]["person_id"], "9")
        self.assertEqual(result[0]["known_for_department"], "Composer")

    @patch("app.providers.services.tmdb.search_people")
    def test_dispatcher_caches_successful_provider_results(self, search_people):
        search_people.return_value = [{
            "source": Sources.TMDB.value,
            "person_id": "819",
            "name": "Edward Norton",
        }]

        first = services.search_people(
            Sources.TMDB.value,
            "Edward Norton",
        )
        second = services.search_people(
            Sources.TMDB.value,
            " Edward   Norton ",
        )

        self.assertEqual(first, second)
        search_people.assert_called_once()
