from unittest.mock import patch

import requests
from django.core.cache import cache
from django.test import TestCase
from rest_framework import status
from rest_framework.test import APIClient

from app.providers.services import ProviderAPIError


class AniListReviewsAPITests(TestCase):
    """Verify the public AniList review-page contract."""

    def setUp(self):
        cache.clear()
        self.client = APIClient()
        self.url = "/api/v1/media/mal/anime/16498/anilist-reviews/"

    @patch("api.services.media.anilist.anime_reviews")
    def test_returns_paginated_reviews(self, reviews_mock):
        reviews_mock.return_value = {
            "current_page": 1,
            "next_page": 2,
            "results": [{"id": "12", "body": "Review"}],
        }

        response = self.client.get(self.url, {"page": 1})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["next_page"], 2)
        self.assertEqual(response.data["results"][0]["id"], "12")
        reviews_mock.assert_called_once_with("16498", 1)

    def test_rejects_invalid_pages(self):
        for page in ("0", "-1", "nope", "1.5"):
            with self.subTest(page=page):
                response = self.client.get(self.url, {"page": page})
                self.assertEqual(
                    response.status_code,
                    status.HTTP_400_BAD_REQUEST,
                )

    def test_rejects_non_mal_anime_identity(self):
        response = self.client.get(
            "/api/v1/media/mal/manga/16498/anilist-reviews/",
        )

        self.assertEqual(response.status_code, status.HTTP_501_NOT_IMPLEMENTED)

    @patch("api.services.media.anilist.anime_reviews")
    def test_returns_standard_provider_unavailable_error(self, reviews_mock):
        reviews_mock.side_effect = ProviderAPIError(
            "anilist",
            requests.Timeout("down"),
        )

        response = self.client.get(self.url)

        self.assertEqual(response.status_code, status.HTTP_503_SERVICE_UNAVAILABLE)
        self.assertEqual(response.data["error"]["code"], "provider_unavailable")
