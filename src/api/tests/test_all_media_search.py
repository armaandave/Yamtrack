import threading
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase
from rest_framework import status
from rest_framework.test import APIClient

from api.services import media as media_service
from app.models import MediaTypes, Sources


class AllMediaSearchTests(TestCase):
    """Contract tests for authenticated flat all-media search."""

    def setUp(self):
        cache.clear()
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(username="all-search", password="password")
        for media_type in (
            MediaTypes.MOVIE.value,
            MediaTypes.TV.value,
            MediaTypes.ANIME.value,
            MediaTypes.MANGA.value,
            MediaTypes.GAME.value,
            MediaTypes.BOOK.value,
            MediaTypes.COMIC.value,
            MediaTypes.MUSIC.value,
        ):
            setattr(self.user, f"{media_type}_enabled", media_type in {MediaTypes.MOVIE.value, MediaTypes.BOOK.value})
        self.user.save()
        self.client.force_authenticate(self.user)

    def test_authenticated_meta_returns_enabled_primary_types(self):
        response = self.client.get("/api/v1/meta/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["enabled_media_types"], [MediaTypes.MOVIE.value, MediaTypes.BOOK.value])

    def test_public_meta_omits_user_enabled_types(self):
        self.client.force_authenticate(user=None)

        response = self.client.get("/api/v1/meta/")

        self.assertNotIn("enabled_media_types", response.data)

    @patch("api.views.media.media_service.search_all_media")
    def test_all_scope_uses_only_enabled_primary_types(self, search_all):
        search_all.return_value = {
            "results": [],
            "completed_media_types": [MediaTypes.MOVIE.value, MediaTypes.BOOK.value],
            "unavailable_media_types": [],
        }

        response = self.client.get(
            "/api/v1/media/search/?scope=all&q=dune&media_types=game,music",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            search_all.call_args.kwargs["media_types"],
            [MediaTypes.MOVIE.value, MediaTypes.BOOK.value],
        )

    def test_all_scope_requires_an_enabled_primary_type(self):
        self.user.movie_enabled = False
        self.user.book_enabled = False
        self.user.save(update_fields=["movie_enabled", "book_enabled"])

        response = self.client.get("/api/v1/media/search/?scope=all&q=dune")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("Enable at least one media type", response.data["media_types"][0])

    def test_all_scope_rejects_pagination_after_page_one(self):
        response = self.client.get("/api/v1/media/search/?scope=all&q=dune&page=2")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("first page", response.data["page"][0])

    @patch("api.views.media.media_service.search_all_media")
    def test_partial_result_names_unavailable_media_types(self, search_all):
        search_all.return_value = {
            "results": [],
            "completed_media_types": [MediaTypes.MOVIE.value],
            "unavailable_media_types": [MediaTypes.BOOK.value],
        }

        response = self.client.get("/api/v1/media/search/?scope=all&q=dune")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 0)
        self.assertIsNone(response.data["next"])
        self.assertIsNone(response.data["previous"])
        self.assertEqual(response.data["unavailable_media_types"], [MediaTypes.BOOK.value])

    @patch("api.views.media.media_service.search_all_media")
    def test_all_provider_failure_returns_standard_error(self, search_all):
        search_all.return_value = {
            "results": [],
            "completed_media_types": [],
            "unavailable_media_types": [MediaTypes.MOVIE.value, MediaTypes.BOOK.value],
        }

        response = self.client.get("/api/v1/media/search/?scope=all&q=dune")

        self.assertEqual(response.status_code, status.HTTP_503_SERVICE_UNAVAILABLE)
        self.assertEqual(response.data["error"]["code"], "provider_unavailable")

    @patch("api.services.media.provider_services.search")
    def test_provider_searches_start_concurrently(self, provider_search):
        barrier = threading.Barrier(2)

        def search(media_type, *_args, **_kwargs):
            barrier.wait(timeout=1)
            return {
                "results": [
                    {
                        "media_id": media_type,
                        "media_type": media_type,
                        "source": Sources.TMDB.value if media_type == MediaTypes.MOVIE.value else Sources.HARDCOVER.value,
                        "title": "Dune",
                    },
                ],
            }

        provider_search.side_effect = search

        payload = media_service.search_all_media(
            media_types=[MediaTypes.MOVIE.value, MediaTypes.BOOK.value],
            query="dune",
        )

        self.assertEqual(payload["completed_media_types"], [MediaTypes.MOVIE.value, MediaTypes.BOOK.value])
        self.assertEqual(len(payload["results"]), 2)
        for call in provider_search.call_args_list:
            self.assertTrue(call.kwargs["preserve_ranking_fields"])
            self.assertEqual(call.kwargs["timeout"], media_service.ALL_MEDIA_SEARCH_TIMEOUT)

    @patch("api.services.media.provider_services.search")
    def test_provider_failure_returns_other_completed_results(self, provider_search):
        def search(media_type, *_args, **_kwargs):
            if media_type == MediaTypes.BOOK.value:
                raise RuntimeError("provider unavailable")
            return {
                "results": [
                    {
                        "media_id": "movie",
                        "media_type": MediaTypes.MOVIE.value,
                        "source": Sources.TMDB.value,
                        "title": "Dune",
                    },
                ],
            }

        provider_search.side_effect = search

        payload = media_service.search_all_media(
            media_types=[MediaTypes.MOVIE.value, MediaTypes.BOOK.value],
            query="dune",
        )

        self.assertEqual(payload["completed_media_types"], [MediaTypes.MOVIE.value])
        self.assertEqual(payload["unavailable_media_types"], [MediaTypes.BOOK.value])
        self.assertEqual([item["title"] for item in payload["results"]], ["Dune"])

    @patch("api.services.media.provider_services.search")
    def test_normal_and_preserved_candidate_caches_are_distinct(self, provider_search):
        provider_search.return_value = {
            "results": [
                {
                    "media_id": "dune",
                    "media_type": MediaTypes.MOVIE.value,
                    "source": Sources.TMDB.value,
                    "title": "Dune",
                    "vote_count": 10_000,
                },
            ],
        }

        specific = media_service.search_media(
            media_type=MediaTypes.MOVIE.value,
            query="dune",
        )
        mixed = media_service.search_all_media(
            media_types=[MediaTypes.MOVIE.value],
            query="dune",
        )

        self.assertEqual(provider_search.call_count, 2)
        self.assertFalse(provider_search.call_args_list[0].kwargs["preserve_ranking_fields"])
        self.assertTrue(provider_search.call_args_list[1].kwargs["preserve_ranking_fields"])
        self.assertEqual(specific[0]["title"], mixed["results"][0]["title"])
        self.assertNotIn("vote_count", mixed["results"][0])

    @patch("api.services.media.ALL_MEDIA_SEARCH_TIMEOUT", 0.01)
    @patch("api.services.media.provider_services.search")
    def test_slow_provider_returns_as_partial_failure(self, provider_search):
        release = threading.Event()

        def search(media_type, *_args, **_kwargs):
            if media_type == MediaTypes.BOOK.value:
                release.wait(timeout=1)
            return {"results": []}

        provider_search.side_effect = search
        try:
            payload = media_service.search_all_media(
                media_types=[MediaTypes.MOVIE.value, MediaTypes.BOOK.value],
                query="dune",
            )
        finally:
            release.set()

        self.assertEqual(payload["completed_media_types"], [MediaTypes.MOVIE.value])
        self.assertEqual(payload["unavailable_media_types"], [MediaTypes.BOOK.value])
