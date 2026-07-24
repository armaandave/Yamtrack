from unittest.mock import patch

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from app.models import ExternalRating, Item, MediaTypes, Sources


class MediaExternalRatingPreparationTests(TestCase):
    """Verify non-blocking media-detail rating preparation."""

    def setUp(self):
        cache.clear()
        self.client = APIClient()
        self.item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Fight Club",
        )

    @staticmethod
    def _metadata():
        return {
            "media_id": "550",
            "media_type": "movie",
            "source": "tmdb",
            "title": "Fight Club",
            "image": "https://example.com/fight-club.jpg",
            "score": "8.4",
            "score_count": 1000,
        }

    @patch("app.providers.tmdb.get_title_logo", return_value=None)
    @patch("app.providers.tmdb.get_backdrop_images", return_value=[])
    @patch("app.providers.mdblist.get_media_ratings")
    @patch("api.services.media.provider_services.get_media_metadata")
    @patch("app.tasks.enrich_external_ratings.delay")
    def test_detail_reports_pending_then_lightweight_endpoint_becomes_ready(
        self,
        enqueue_mock,
        metadata_mock,
        mdblist_mock,
        _backdrops_mock,
        _logo_mock,
    ):
        metadata_mock.return_value = self._metadata()

        detail = self.client.get("/api/v1/media/tmdb/movie/550/")

        self.assertEqual(detail.status_code, status.HTTP_200_OK)
        self.assertEqual(
            detail.data["external_ratings_preparation"],
            {"state": "pending", "retry_after_seconds": 2},
        )
        self.assertEqual(
            [(rating["source"], rating["value"]) for rating in detail.data["external_ratings"]],
            [("TMDB", "8.4")],
        )
        enqueue_mock.assert_called_once_with(
            self.item.pk,
            ["imdb", "letterboxd", "tomatoes"],
        )
        mdblist_mock.assert_not_called()

        now = timezone.now()
        for source, value, maximum in (
            ("imdb", "8.8", 10),
            ("letterboxd", "4.3", 5),
            ("tomatoes", 79, 100),
        ):
            ExternalRating.objects.create(
                item=self.item,
                rating_source=source,
                value=value,
                max_value=maximum,
                status=ExternalRating.Status.AVAILABLE,
                last_attempted_at=now,
                last_success_at=now,
            )

        ratings = self.client.get("/api/v1/media/tmdb/movie/550/external-ratings/")

        self.assertEqual(ratings.status_code, status.HTTP_200_OK)
        self.assertEqual(
            ratings.data["external_ratings_preparation"],
            {"state": "ready", "retry_after_seconds": 2},
        )
        self.assertEqual(
            [rating["source"] for rating in ratings.data["external_ratings"]],
            ["TMDB", "IMDb", "Letterboxd", "Rotten Tomatoes"],
        )
        mdblist_mock.assert_not_called()

    @patch("app.tasks.enrich_external_ratings.delay")
    @patch("app.providers.mdblist.get_media_ratings")
    def test_polling_endpoint_deduplicates_enqueue_and_never_fetches_provider(
        self,
        mdblist_mock,
        enqueue_mock,
    ):
        first = self.client.get("/api/v1/media/tmdb/movie/550/external-ratings/")
        second = self.client.get("/api/v1/media/tmdb/movie/550/external-ratings/")

        self.assertEqual(first.data["external_ratings_preparation"]["state"], "pending")
        self.assertEqual(second.data["external_ratings_preparation"]["state"], "pending")
        enqueue_mock.assert_called_once()
        mdblist_mock.assert_not_called()

    @patch("app.tasks.enrich_external_ratings.delay")
    def test_recent_failed_source_reports_degraded(self, _enqueue_mock):
        ExternalRating.objects.create(
            item=self.item,
            rating_source="imdb",
            status=ExternalRating.Status.FAILED,
            last_attempted_at=timezone.now(),
            last_error="provider unavailable",
        )

        response = self.client.get("/api/v1/media/tmdb/movie/550/external-ratings/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["external_ratings_preparation"]["state"], "degraded")

    @patch("app.providers.steam.get_review_rating")
    @patch("app.providers.steam.get_metacritic_rating")
    @patch("app.tasks.enrich_external_ratings.delay")
    def test_game_polling_adds_steam_without_fetching_or_dropping_cached_ratings(
        self,
        enqueue_mock,
        metacritic_mock,
        steam_mock,
    ):
        game = Item.objects.create(
            source=Sources.IGDB.value,
            media_type=MediaTypes.GAME.value,
            media_id="119133",
            title="Elden Ring",
        )
        now = timezone.now()
        for source, value, maximum, url in (
            ("igdb", "96", 100, "https://www.igdb.com/games/elden-ring"),
            (
                "metacritic",
                "94",
                100,
                "https://www.metacritic.com/game/elden-ring/",
            ),
        ):
            ExternalRating.objects.create(
                item=game,
                rating_source=source,
                value=value,
                max_value=maximum,
                canonical_url=url,
                status=ExternalRating.Status.AVAILABLE,
                last_attempted_at=now,
                last_success_at=now,
            )

        pending = self.client.get(
            "/api/v1/media/igdb/game/119133/external-ratings/",
        )

        self.assertEqual(
            pending.data["external_ratings_preparation"]["state"],
            "pending",
        )
        self.assertEqual(
            [rating["source"] for rating in pending.data["external_ratings"]],
            ["IGDB", "Metacritic"],
        )
        enqueue_mock.assert_called_once_with(game.pk, ["steam"])
        metacritic_mock.assert_not_called()
        steam_mock.assert_not_called()

        ExternalRating.objects.create(
            item=game,
            rating_source="steam",
            value=92,
            max_value=100,
            vote_count=123456,
            canonical_url="https://store.steampowered.com/app/1245620/",
            status=ExternalRating.Status.AVAILABLE,
            last_attempted_at=now,
            last_success_at=now,
        )
        ready = self.client.get(
            "/api/v1/media/igdb/game/119133/external-ratings/",
        )

        self.assertEqual(
            ready.data["external_ratings_preparation"]["state"],
            "ready",
        )
        self.assertEqual(
            [rating["source"] for rating in ready.data["external_ratings"]],
            ["IGDB", "Metacritic", "Steam"],
        )
        self.assertEqual(ready.data["external_ratings"][2]["value"], "92%")
        self.assertEqual(ready.data["external_ratings"][2]["vote_count"], 123456)

    @patch("app.providers.steam.get_review_rating")
    @patch("app.providers.steam.get_metacritic_rating")
    @patch("app.tasks.enrich_external_ratings.delay")
    @patch("app.providers.steamgriddb.get_game_logo", return_value=None)
    @patch("api.services.media._game_default_backdrop_url", return_value=None)
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_untracked_game_detail_materializes_item_and_queues_steam(
        self,
        metadata_mock,
        _backdrop_mock,
        _logo_mock,
        enqueue_mock,
        metacritic_mock,
        steam_mock,
    ):
        metadata_mock.return_value = {
            "media_id": "386",
            "media_type": "game",
            "source": "igdb",
            "title": "Battlefield 4",
            "image": "https://example.com/battlefield-4.jpg",
            "score": "78",
            "score_count": 908,
        }

        response = self.client.get("/api/v1/media/igdb/game/386/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            response.data["external_ratings_preparation"],
            {"state": "pending", "retry_after_seconds": 2},
        )
        game = Item.objects.get(
            source=Sources.IGDB.value,
            media_type=MediaTypes.GAME.value,
            media_id="386",
        )
        enqueue_mock.assert_called_once_with(game.pk, ["metacritic", "steam"])
        metacritic_mock.assert_not_called()
        steam_mock.assert_not_called()
