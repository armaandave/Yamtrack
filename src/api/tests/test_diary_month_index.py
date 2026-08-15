from datetime import UTC, datetime

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework import status
from rest_framework.test import APIClient

from app.models import DiaryEntry, Item, MediaTypes, Sources


class DiaryMonthIndexTests(TestCase):
    """Verify bounded month navigation queries for the native diary."""

    def setUp(self):
        self.user = get_user_model().objects.create_user(username="months", password="password-123")
        self.other = get_user_model().objects.create_user(username="other-months", password="password-123")
        self.movie = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="month-movie",
            title="Month Movie",
        )
        self.book = Item.objects.create(
            source=Sources.HARDCOVER.value,
            media_type=MediaTypes.BOOK.value,
            media_id="month-book",
            title="Month Book",
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def test_month_index_returns_counts_without_other_users(self):
        self._entry(self.user, self.movie, 2026, 6, 20)
        self._entry(self.user, self.book, 2026, 6, 10)
        self._entry(self.user, self.movie, 2026, 5, 1)
        self._entry(self.other, self.movie, 2026, 4, 1)

        response = self.client.get("/api/v1/diary/months/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            response.data,
            [
                {"month": "2026-06", "count": 2},
                {"month": "2026-05", "count": 1},
            ],
        )

    def test_month_filter_returns_only_the_selected_filtered_month(self):
        june_movie = self._entry(self.user, self.movie, 2026, 6, 20)
        self._entry(self.user, self.book, 2026, 6, 10)
        self._entry(self.user, self.movie, 2026, 5, 1)

        response = self.client.get(
            "/api/v1/diary/",
            {"month": "2026-06", "media_type": MediaTypes.MOVIE.value},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 1)
        self.assertEqual(response.data["results"][0]["id"], june_movie.id)

    def test_month_filter_rejects_invalid_values(self):
        response = self.client.get("/api/v1/diary/", {"month": "June 2026"})

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["error"]["fields"]["month"], ["Use YYYY-MM."])

    @staticmethod
    def _entry(user, item, year, month, day):
        return DiaryEntry.objects.create(
            user=user,
            item=item,
            consumed_at=datetime(year, month, day, tzinfo=UTC),
        )
