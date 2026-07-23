from datetime import timedelta
from unittest.mock import patch

from django.core.cache import cache
from django.db import connection
from django.test import TestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework import status

from app.models import DiaryEntry, ExternalRating, Item, MediaTypes, Movie, Sources
from lists.models import CustomListItem


class PersonExternalRatingSortTests(TestCase):
    """Verify cached external-rating preparation for provider filmographies."""

    def setUp(self):
        cache.clear()

    @staticmethod
    def _person(person_credits, source=Sources.TMDB.value):
        return {
            "source": source,
            "person_id": "person-1",
            "name": "Person",
            "credits": person_credits,
        }

    @staticmethod
    def _credit(media_id, title, source=Sources.TMDB.value, media_type=MediaTypes.MOVIE.value):
        return {
            "source": source,
            "media_type": media_type,
            "media_id": str(media_id),
            "title": title,
            "image": f"https://example.com/{media_id}.jpg",
            "release_date": "2024-01-02",
            "year": "2024",
            "genres": ["Drama"],
            "languages": ["English"],
        }

    @patch("app.tasks.enrich_external_ratings_batch.delay")
    @patch("api.services.media.refresh_external_ratings")
    @patch("api.services.media.provider_services.get_person_page")
    def test_materializes_large_filmography_and_queues_bounded_batches(
        self,
        person_mock,
        refresh_mock,
        delay_mock,
    ):
        person_credits = [self._credit(index, f"Movie {index:03}") for index in range(1, 106)]
        person_mock.return_value = self._person(person_credits)

        with self.captureOnCommitCallbacks(execute=True), CaptureQueriesContext(connection) as queries:
            response = self.client.get(
                "/api/v1/people/tmdb/person-1/",
                {"sort": "rating:imdb"},
            )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertLess(len(queries), 20)
        self.assertEqual(Item.objects.filter(source=Sources.TMDB.value).count(), 105)
        self.assertEqual(Movie.objects.count(), 0)
        self.assertEqual(DiaryEntry.objects.count(), 0)
        self.assertEqual(CustomListItem.objects.count(), 0)
        self.assertEqual(
            response.data["rating_preparation"],
            {
                "rating_source": "imdb",
                "state": "pending",
                "total": 105,
                "ready": 0,
                "unavailable": 0,
                "failed": 0,
            },
        )
        self.assertEqual([len(call.args[0]) for call in delay_mock.call_args_list], [100, 5])
        person_mock.assert_called_once_with(Sources.TMDB.value, "person-1")
        refresh_mock.assert_not_called()

        with self.captureOnCommitCallbacks(execute=True):
            self.client.get(
                "/api/v1/people/tmdb/person-1/",
                {"sort": "rating:imdb"},
            )
        self.assertEqual(delay_mock.call_count, 2)

    @patch("app.tasks.enqueue_external_rating_batches")
    @patch("api.services.media.provider_services.get_person_page")
    def test_cached_values_sort_with_nulls_last_and_report_degraded(
        self,
        person_mock,
        enqueue_mock,
    ):
        now = timezone.now()
        fixtures = [
            ("alpha", "alpha", "9", ExternalRating.Status.AVAILABLE),
            ("zulu", "Zulu", "9", ExternalRating.Status.AVAILABLE),
            ("middle", "Middle", "8", ExternalRating.Status.AVAILABLE),
            ("failed", "Failed", "7", ExternalRating.Status.FAILED),
            ("none", "No Rating", None, ExternalRating.Status.UNAVAILABLE),
        ]
        person_credits = []
        for media_id, title, value, rating_status in fixtures:
            item = Item.objects.create(
                source=Sources.TMDB.value,
                media_type=MediaTypes.MOVIE.value,
                media_id=media_id,
                title=title,
                image=f"https://example.com/{media_id}.jpg",
            )
            ExternalRating.objects.create(
                item=item,
                rating_source="imdb",
                value=value,
                max_value=10,
                status=rating_status,
                last_attempted_at=now,
                last_success_at=now if value is not None else None,
            )
            person_credits.append(self._credit(media_id, title))
        person_mock.return_value = self._person(person_credits)

        with self.captureOnCommitCallbacks(execute=True):
            response = self.client.get(
                "/api/v1/people/tmdb/person-1/",
                {"sort": "rating:imdb"},
            )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [credit["title"] for credit in response.data["credits"]["cast"]],
            ["alpha", "Zulu", "Middle", "Failed", "No Rating"],
        )
        self.assertEqual(
            response.data["rating_preparation"],
            {
                "rating_source": "imdb",
                "state": "degraded",
                "total": 5,
                "ready": 3,
                "unavailable": 1,
                "failed": 1,
            },
        )
        enqueue_mock.assert_called_once()

        response = self.client.get(
            "/api/v1/people/tmdb/person-1/",
            {"sort": "imdb_rating", "direction": "asc"},
        )
        self.assertEqual(
            [credit["title"] for credit in response.data["credits"]["cast"]],
            ["Failed", "Middle", "alpha", "Zulu", "No Rating"],
        )

    @patch("api.services.media.provider_services.get_person_page")
    def test_dynamic_options_and_rating_sort_validation(self, person_mock):
        person_mock.return_value = self._person(
            [
                self._credit(
                    "book-1",
                    "Book",
                    source=Sources.HARDCOVER.value,
                    media_type=MediaTypes.BOOK.value,
                ),
            ],
            source=Sources.HARDCOVER.value,
        )

        response = self.client.get("/api/v1/people/hardcover/person-1/")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIsNone(response.data["rating_preparation"])
        self.assertEqual(
            [choice["value"] for choice in response.data["filter_options"]["sorts"]],
            ["title", "release_date", "average_rating", "rating:hardcover"],
        )

        for sort in ("rating:imdb", "rating:unknown", "rating-imdb"):
            with self.subTest(sort=sort):
                response = self.client.get(
                    "/api/v1/people/hardcover/person-1/",
                    {"sort": sort},
                )
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertIn("sort", response.data["error"]["fields"])

    @override_settings(EXTERNAL_RATING_PERSON_PREPARATION_ENABLED=False)
    @patch("api.services.media.provider_services.get_person_page")
    def test_person_preparation_rollout_gate(self, person_mock):
        person_mock.return_value = self._person([self._credit("movie", "Movie")])

        options = self.client.get("/api/v1/people/tmdb/person-1/")
        rejected = self.client.get(
            "/api/v1/people/tmdb/person-1/",
            {"sort": "rating:imdb"},
        )

        self.assertEqual(options.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [choice["value"] for choice in options.data["filter_options"]["sorts"]],
            ["title", "release_date", "average_rating"],
        )
        self.assertEqual(rejected.status_code, status.HTTP_400_BAD_REQUEST)

    @patch("api.services.media.provider_services.get_person_page")
    def test_pending_preparation_survives_cache_outage(self, person_mock):
        person_mock.return_value = self._person([self._credit("missing", "Missing")])

        with (
            patch("api.services.media.cache.add", side_effect=ConnectionError),
            patch("app.tasks.enqueue_external_rating_batches") as enqueue_mock,
        ):
            response = self.client.get(
                "/api/v1/people/tmdb/person-1/",
                {"sort": "rating:imdb"},
            )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["rating_preparation"]["state"], "pending")
        enqueue_mock.assert_not_called()

    @patch("api.services.media.provider_services.get_person_page")
    def test_ready_sort_does_not_touch_rating_infrastructure(self, person_mock):
        now = timezone.now()
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="ready",
            title="Ready",
        )
        ExternalRating.objects.create(
            item=item,
            rating_source="imdb",
            value="8",
            max_value=10,
            status=ExternalRating.Status.AVAILABLE,
            last_attempted_at=now,
            last_success_at=now,
        )
        person_mock.return_value = self._person([self._credit("ready", "Ready")])

        with (
            patch("api.services.media.cache.add", side_effect=AssertionError),
            patch("app.tasks.enqueue_external_rating_batches", side_effect=AssertionError),
            patch("app.external_ratings.refresh_external_ratings", side_effect=AssertionError),
        ):
            response = self.client.get(
                "/api/v1/people/tmdb/person-1/",
                {"sort": "rating:imdb"},
            )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["rating_preparation"]["state"], "ready")

    def test_exact_episode_identities_materialize_separately(self):
        from api.services.media import _materialize_person_credits

        person_credits = [
            {
                **self._credit("show", "Episode 1", media_type=MediaTypes.EPISODE.value),
                "season_number": 1,
                "episode_number": episode,
            }
            for episode in (1, 2)
        ]

        items = _materialize_person_credits(person_credits)

        self.assertEqual(len(items), 2)
        self.assertEqual(
            set(Item.objects.values_list("season_number", "episode_number")),
            {(1, 1), (1, 2)},
        )

    def test_stale_available_row_is_pending_but_keeps_partial_order(self):
        now = timezone.now()
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="stale",
            title="Stale",
            image="https://example.com/stale.jpg",
        )
        ExternalRating.objects.create(
            item=item,
            rating_source="imdb",
            value="8",
            max_value=10,
            status=ExternalRating.Status.AVAILABLE,
            last_attempted_at=now - timedelta(days=2),
            last_success_at=now - timedelta(days=2),
        )
        person = self._person(
            [
                self._credit("missing", "Missing"),
                self._credit("stale", "Stale"),
            ],
        )

        with (
            patch(
                "api.services.media.provider_services.get_person_page",
                return_value=person,
            ),
            patch("app.tasks.enqueue_external_rating_batches") as enqueue_mock,
            self.captureOnCommitCallbacks(execute=True),
        ):
            response = self.client.get(
                "/api/v1/people/tmdb/person-1/",
                {"sort": "rating:imdb"},
            )

        self.assertEqual(
            [credit["title"] for credit in response.data["credits"]["cast"]],
            ["Stale", "Missing"],
        )
        self.assertEqual(response.data["rating_preparation"]["state"], "pending")
        self.assertEqual(response.data["rating_preparation"]["ready"], 0)
        self.assertEqual(enqueue_mock.call_args.args[1], ["imdb"])
