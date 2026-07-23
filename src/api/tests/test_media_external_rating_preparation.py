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
