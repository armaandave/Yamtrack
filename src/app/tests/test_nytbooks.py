import requests
from unittest.mock import patch

from django.test import SimpleTestCase, override_settings

from app.providers import nytbooks


@override_settings(NYT_BOOKS_API_KEY="test-secret")
class NYTBooksProviderTests(SimpleTestCase):
    def test_featured_chart_allowlist_and_positions_are_stable(self):
        self.assertEqual(
            [
                (chart["slug"], chart["featured_position"])
                for chart in nytbooks.FEATURED_CHARTS
            ],
            [
                ("combined-print-and-e-book-fiction", 2),
                ("combined-print-and-e-book-nonfiction", 3),
                ("advice-how-to-and-miscellaneous", 4),
                ("business-books", 5),
                ("graphic-books-and-manga", 6),
            ],
        )

    @patch("app.providers.nytbooks.services.api_request")
    def test_chart_normalizes_rank_and_prioritizes_isbn13(self, api_request):
        api_request.return_value = {
            "results": {
                "list_name_encoded": "business-books",
                "display_name": "Business Books",
                "published_date": "2026-07-19",
                "books": [
                    {
                        "rank": 2,
                        "title": "Second",
                        "primary_isbn10": "TEN-2",
                        "primary_isbn13": "THIRTEEN-2",
                        "isbns": [
                            {"isbn10": "TEN-ALT", "isbn13": "THIRTEEN-ALT"},
                            {"isbn10": "TEN-2", "isbn13": "THIRTEEN-2"},
                        ],
                    },
                    {
                        "rank": 1,
                        "title": "First",
                        "primary_isbn13": "THIRTEEN-1",
                    },
                ],
            },
        }

        chart = nytbooks.get_current_chart("business-books", "Business Books")

        self.assertEqual(chart["published_date"], "2026-07-19")
        self.assertEqual([book["rank"] for book in chart["books"]], [1, 2])
        self.assertEqual(
            chart["books"][1]["isbns"],
            ["THIRTEEN-2", "THIRTEEN-ALT", "TEN-2", "TEN-ALT"],
        )
        api_request.assert_called_once_with(
            "nyt books",
            "GET",
            "https://api.nytimes.com/svc/books/v3/lists/current/business-books.json",
            params={"api-key": "test-secret"},
        )

    @patch("app.providers.nytbooks.services.api_request", return_value={"results": {}})
    def test_empty_chart_is_rejected(self, _api_request):
        with self.assertRaisesMessage(nytbooks.NYTBooksError, "malformed or empty"):
            nytbooks.get_current_chart("business-books", "Business Books")

    @patch("app.providers.nytbooks.services.api_request")
    def test_provider_errors_never_include_api_key_or_url(self, api_request):
        api_request.side_effect = requests.ConnectionError(
            "failed https://api.nytimes.com/example?api-key=test-secret",
        )

        with self.assertRaises(nytbooks.NYTBooksError) as raised:
            nytbooks.get_current_chart("business-books", "Business Books")

        message = str(raised.exception)
        self.assertNotIn("test-secret", message)
        self.assertNotIn("api.nytimes.com", message)

    @patch("app.providers.nytbooks.services.api_request")
    def test_authentication_error_reports_only_status(self, api_request):
        response = requests.Response()
        response.status_code = 401
        api_request.side_effect = requests.HTTPError(
            "https://api.nytimes.com/example?api-key=test-secret",
            response=response,
        )

        with self.assertRaisesMessage(nytbooks.NYTBooksError, "HTTP 401") as raised:
            nytbooks.get_current_chart("business-books", "Business Books")

        self.assertNotIn("test-secret", str(raised.exception))

    @override_settings(NYT_BOOKS_API_KEY="")
    def test_missing_key_fails_without_request(self):
        with patch("app.providers.nytbooks.services.api_request") as api_request:
            with self.assertRaisesMessage(nytbooks.NYTBooksError, "not configured"):
                nytbooks.get_current_chart("business-books", "Business Books")
        api_request.assert_not_called()
