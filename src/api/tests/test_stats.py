from datetime import datetime
from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from app.models import (
    Book,
    DiaryEntry,
    Item,
    ItemFilterFacet,
    MediaLike,
    MediaTypes,
    Movie,
    Sources,
    Status,
)
from social.models import Follow, FollowStatus


class StatsAPITests(TestCase):
    """Exercise the additive native stats contract and its privacy rules."""

    def setUp(self):
        self.client = APIClient()
        self.user = get_user_model().objects.create_user(
            username="stats-user",
            password="strong-password-123",
        )

    def test_stats_requires_authentication(self):
        response = self.client.get("/api/v1/stats/me/summary/")

        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_empty_stats_have_stable_native_shape_and_legacy_keys(self):
        self.client.force_authenticate(self.user)

        response = self.client.get(
            "/api/v1/stats/me/summary/",
            {"start_date": "all", "end_date": "all"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        for legacy_key in (
            "start_date",
            "end_date",
            "media_count",
            "media_type_distribution",
            "score_distribution",
            "status_distribution",
            "top_rated",
        ):
            self.assertIn(legacy_key, response.data)

        self.assertEqual(response.data["schema_version"], 1)
        self.assertEqual(
            response.data["range"],
            {
                "start_date": None,
                "end_date": None,
                "timezone": timezone.get_current_timezone_name(),
                "is_all_time": True,
            },
        )
        self.assertEqual(response.data["overview"]["tracked_count"], 0)
        self.assertEqual(response.data["overview"]["diary_entry_count"], 0)
        self.assertEqual(response.data["overview"]["average_rating"], None)
        self.assertEqual(response.data["activity"]["days"], [])
        self.assertIsNone(response.data["activity"]["most_active_weekday"])
        self.assertEqual(len(response.data["rating_distribution"]), 21)
        self.assertEqual(response.data["rating_distribution"][1], {"rating": "0.5", "count": 0})
        self.assertEqual(
            [entry["media_type"] for entry in response.data["media_types"]],
            ["movie", "tv", "anime", "manga", "game", "book", "comic"],
        )
        for entry in response.data["media_types"]:
            self.assertEqual(entry["tracked_count"], 0)
            self.assertEqual(entry["rating_distribution"][0], {"rating": "0.0", "count": 0})
            self.assertEqual(entry["top_rated"], [])
            self.assertEqual(entry["most_logged"], [])

    @patch("app.providers.services.get_media_metadata")
    def test_populated_stats_use_local_tracking_diary_and_metadata(self, metadata_mock):
        movie_item = Item.objects.create(
            media_id="550",
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            title="Fight Club",
            image="https://example.com/fight-club.jpg",
            release_year=1999,
        )
        book_item = Item.objects.create(
            media_id="book-1",
            source=Sources.HARDCOVER.value,
            media_type=MediaTypes.BOOK.value,
            title="A Book",
            image="https://example.com/book.jpg",
            release_year=2020,
        )
        watched_at = self._aware(2026, 1, 10)
        Movie.objects.bulk_create([
            Movie(
                user=self.user,
                item=movie_item,
                status=Status.COMPLETED.value,
                score=Decimal("9.0"),
                start_date=watched_at,
                end_date=watched_at,
            ),
        ])
        Book.objects.bulk_create([
            Book(
                user=self.user,
                item=book_item,
                status=Status.PLANNING.value,
            ),
        ])
        DiaryEntry.objects.bulk_create([
            DiaryEntry(
                user=self.user,
                item=movie_item,
                consumed_at=watched_at,
                rating=Decimal("8.5"),
                review="Sharp and restless.",
                visibility="public",
            ),
            DiaryEntry(
                user=self.user,
                item=movie_item,
                consumed_at=self._aware(2026, 1, 11),
                rating=Decimal("9.0"),
                is_rewatch=True,
                visibility="public",
            ),
        ])
        ItemFilterFacet.objects.bulk_create([
            ItemFilterFacet(
                item=movie_item,
                facet_type=ItemFilterFacet.FacetType.GENRE,
                value="Drama",
            ),
            ItemFilterFacet(
                item=movie_item,
                facet_type=ItemFilterFacet.FacetType.LANGUAGE,
                value="English",
            ),
        ])
        MediaLike.objects.create(user=self.user, item=movie_item)
        self.client.force_authenticate(self.user)

        response = self.client.get(
            "/api/v1/stats/me/summary/",
            {"start_date": "2026-01-01", "end_date": "2026-01-31"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        metadata_mock.assert_not_called()
        overview = response.data["overview"]
        self.assertEqual(overview["tracked_count"], 2)
        self.assertEqual(overview["completed_count"], 1)
        self.assertEqual(overview["diary_entry_count"], 2)
        self.assertEqual(overview["unique_logged_count"], 1)
        self.assertEqual(overview["repeat_count"], 1)
        self.assertEqual(overview["rated_count"], 2)
        self.assertEqual(overview["average_rating"], "8.75")
        self.assertEqual(overview["review_count"], 1)
        self.assertEqual(overview["liked_count"], 1)
        self.assertEqual(overview["active_days"], 2)
        self.assertEqual(overview["longest_streak_days"], 2)

        distribution = {
            entry["rating"]: entry["count"]
            for entry in response.data["rating_distribution"]
        }
        self.assertEqual(distribution["8.5"], 1)
        self.assertEqual(distribution["9.0"], 1)
        self.assertEqual(response.data["release_years"], [{"year": 1999, "count": 1}])
        self.assertEqual(response.data["top_genres"], [{"name": "Drama", "count": 1}])
        self.assertEqual(response.data["top_languages"], [{"name": "English", "count": 1}])
        self.assertEqual(
            response.data["metadata_coverage"],
            {
                "total_items": 1,
                "release_year_items": 1,
                "genre_items": 1,
                "language_items": 1,
            },
        )
        self.assertEqual(response.data["top_rated"][0]["rating"], "9.0")
        self.assertIsNone(response.data["top_rated"][0]["media"]["user_state"])
        self.assertEqual(response.data["most_logged"][0]["log_count"], 2)
        self.assertEqual(
            response.data["activity"]["most_active_weekday"],
            {
                "weekday": 5,
                "name": "Saturday",
                "active_day_count": 1,
                "percentage": 50.0,
            },
        )

        movie_stats = self._media_stats(response, MediaTypes.MOVIE.value)
        self.assertEqual(movie_stats["tracked_count"], 1)
        self.assertEqual(movie_stats["completed_count"], 1)
        self.assertEqual(movie_stats["statuses"]["completed"], 1)
        self.assertEqual(movie_stats["diary_entry_count"], 2)
        self.assertEqual(movie_stats["top_rated"][0]["rating"], "9.0")
        self.assertEqual(movie_stats["most_logged"][0]["log_count"], 2)
        self.assertEqual(movie_stats["release_years"], [{"year": 1999, "count": 1}])

    def test_stats_validate_dates_including_all_time_and_leap_day(self):
        self.client.force_authenticate(self.user)

        invalid = self.client.get(
            "/api/v1/stats/me/summary/",
            {"start_date": "not-a-date", "end_date": "2026-01-01"},
        )
        reversed_range = self.client.get(
            "/api/v1/stats/me/summary/",
            {"start_date": "2026-02-01", "end_date": "2026-01-01"},
        )
        mismatched_all = self.client.get(
            "/api/v1/stats/me/summary/",
            {"start_date": "all", "end_date": "2026-01-01"},
        )
        leap_day = self.client.get(
            "/api/v1/stats/me/summary/",
            {"start_date": "2024-02-29", "end_date": "2024-03-01"},
        )

        self.assertEqual(invalid.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(reversed_range.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(mismatched_all.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(leap_day.status_code, status.HTTP_200_OK)
        self.assertEqual(leap_day.data["range"]["start_date"], "2024-02-29")

    def test_season_and_episode_logs_roll_up_into_stable_tv_bucket(self):
        items = [
            Item.objects.create(
                media_id="tv-rollup",
                source=Sources.TMDB.value,
                media_type=MediaTypes.TV.value,
                title="Rollup Show",
                image="https://example.com/show.jpg",
            ),
            Item.objects.create(
                media_id="tv-rollup",
                source=Sources.TMDB.value,
                media_type=MediaTypes.SEASON.value,
                season_number=1,
                title="Rollup Show",
                image="https://example.com/season.jpg",
            ),
            Item.objects.create(
                media_id="tv-rollup",
                source=Sources.TMDB.value,
                media_type=MediaTypes.EPISODE.value,
                season_number=1,
                episode_number=1,
                title="Pilot",
                image="https://example.com/episode.jpg",
            ),
        ]
        DiaryEntry.objects.bulk_create([
            DiaryEntry(
                user=self.user,
                item=item,
                consumed_at=self._aware(2026, 3, index + 1),
                visibility="public",
            )
            for index, item in enumerate(items)
        ])
        self.client.force_authenticate(self.user)

        response = self.client.get(
            "/api/v1/stats/me/summary/",
            {"start_date": "2026-03-01", "end_date": "2026-03-31"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        tv_stats = self._media_stats(response, MediaTypes.TV.value)
        self.assertEqual(tv_stats["diary_entry_count"], 3)
        self.assertEqual(tv_stats["unique_logged_count"], 3)
        self.assertNotIn(
            MediaTypes.SEASON.value,
            [entry["media_type"] for entry in response.data["media_types"]],
        )
        self.assertNotIn(
            MediaTypes.EPISODE.value,
            [entry["media_type"] for entry in response.data["media_types"]],
        )

    def test_public_user_stats_honor_entry_visibility_and_omit_target_state(self):
        target = get_user_model().objects.create_user(
            username="public-stats-user",
            password="strong-password-123",
            profile_private=False,
        )
        viewer = get_user_model().objects.create_user(
            username="stats-viewer",
            password="strong-password-123",
        )
        items = [
            Item.objects.create(
                media_id=f"visible-{index}",
                source=Sources.TMDB.value,
                media_type=MediaTypes.MOVIE.value,
                title=f"Visibility {index}",
                image=f"https://example.com/{index}.jpg",
            )
            for index in range(3)
        ]
        DiaryEntry.objects.bulk_create([
            DiaryEntry(
                user=target,
                item=items[0],
                consumed_at=self._aware(2026, 2, 1),
                rating=Decimal("7.0"),
                visibility="public",
            ),
            DiaryEntry(
                user=target,
                item=items[1],
                consumed_at=self._aware(2026, 2, 2),
                rating=Decimal("8.0"),
                visibility="followers",
            ),
            DiaryEntry(
                user=target,
                item=items[2],
                consumed_at=self._aware(2026, 2, 3),
                rating=Decimal("10.0"),
                visibility="private",
            ),
        ])
        Movie.objects.bulk_create([
            Movie(
                user=target,
                item=items[0],
                status=Status.COMPLETED.value,
                score=Decimal("2.0"),
            ),
            Movie(
                user=target,
                item=items[2],
                status=Status.COMPLETED.value,
                score=Decimal("10.0"),
            ),
        ])
        self.client.force_authenticate(viewer)

        public_response = self.client.get(
            f"/api/v1/users/{target.username}/stats/summary/",
            {"start_date": "all", "end_date": "all"},
        )

        self.assertEqual(public_response.status_code, status.HTTP_200_OK)
        self.assertEqual(public_response.data["overview"]["diary_entry_count"], 1)
        self.assertEqual(public_response.data["diary_top_rated"][0]["rating"], "7.0")
        self.assertIsNone(public_response.data["diary_top_rated"][0]["media"]["user_state"])
        self.assertEqual(public_response.data["score_distribution"]["total_scored"], 1)
        self.assertEqual(public_response.data["score_distribution"]["average_score"], 7.0)
        self.assertEqual(public_response.data["top_rated"][0]["rating"], "7.0")

        Follow.objects.create(
            from_user=viewer,
            to_user=target,
            status=FollowStatus.ACCEPTED,
        )
        follower_response = self.client.get(
            f"/api/v1/users/{target.username}/stats/summary/",
            {"start_date": "all", "end_date": "all"},
        )

        self.assertEqual(follower_response.status_code, status.HTTP_200_OK)
        self.assertEqual(follower_response.data["overview"]["diary_entry_count"], 2)
        self.assertEqual(follower_response.data["diary_top_rated"][0]["rating"], "8.0")
        self.assertEqual(follower_response.data["score_distribution"]["total_scored"], 2)
        self.assertEqual(follower_response.data["score_distribution"]["average_score"], 7.5)
        returned_ids = {
            entry["media"]["ref"]["item_id"]
            for entry in follower_response.data["diary_top_rated"]
        }
        self.assertNotIn(items[2].id, returned_ids)

    @staticmethod
    def _aware(year, month, day):
        return datetime(
            year,
            month,
            day,
            12,
            tzinfo=timezone.get_current_timezone(),
        )

    @staticmethod
    def _media_stats(response, media_type):
        return next(
            entry
            for entry in response.data["media_types"]
            if entry["media_type"] == media_type
        )
