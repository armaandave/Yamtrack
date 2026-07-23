from unittest.mock import MagicMock, patch

import requests
from django.conf import settings
from django.core.cache import cache
from django.test import TestCase

from app.models import MediaTypes, Sources
from app.providers import hardcover, openlibrary, services


class HardcoverISBNLookupTests(TestCase):
    def setUp(self):
        cache.clear()

    @patch("app.providers.hardcover.services.api_request")
    def test_returns_book_for_exact_edition_and_caches_result(self, mock_api_request):
        mock_api_request.return_value = {
            "data": {
                "editions": [
                    {
                        "isbn_10": "097522980X",
                        "isbn_13": "9780975229804",
                        "pages": 432,
                        "book": {
                            "id": 123,
                            "title": "A Fictional Book",
                            "pages": 410,
                            "cached_image": "https://example.com/cover.jpg",
                            "cached_contributors": "Example Author",
                        },
                    },
                ],
            },
        }

        first = hardcover.lookup_book_by_isbn(" 097522980x ")
        second = hardcover.lookup_book_by_isbn("097522980X")

        self.assertEqual(first, second)
        self.assertEqual(
            first,
            {
                "media_id": "123",
                "source": Sources.HARDCOVER.value,
                "media_type": MediaTypes.BOOK.value,
                "title": "A Fictional Book",
                "image": "https://example.com/cover.jpg",
                "max_progress": 432,
                "total_pages": 432,
                "author_name": "Example Author",
                "matched_isbn": "097522980X",
            },
        )
        mock_api_request.assert_called_once()
        args, kwargs = mock_api_request.call_args
        self.assertEqual(
            args,
            (Sources.HARDCOVER.value, "POST", hardcover.base_url),
        )
        self.assertEqual(kwargs["params"]["variables"], {"isbn": "097522980X"})
        query = kwargs["params"]["query"]
        self.assertIn("editions(", query)
        self.assertIn("{isbn_13: {_eq: $isbn}}", query)
        self.assertIn("{isbn_10: {_eq: $isbn}}", query)
        self.assertIn("order_by: {users_count: desc}", query)

    @patch("app.providers.hardcover.services.api_request")
    def test_missing_edition_is_negatively_cached(self, mock_api_request):
        mock_api_request.return_value = {"data": {"editions": []}}

        self.assertIsNone(hardcover.lookup_book_by_isbn("9780975229804"))
        self.assertIsNone(hardcover.lookup_book_by_isbn("9780975229804"))

        mock_api_request.assert_called_once()
        self.assertIs(
            cache.get(f"isbn_{Sources.HARDCOVER.value}_9780975229804"),
            False,
        )

    @patch("app.providers.hardcover.services.api_request")
    def test_network_error_uses_provider_error_contract(self, mock_api_request):
        mock_api_request.side_effect = requests.ConnectionError("connection failed")

        with self.assertRaises(services.ProviderAPIError) as raised:
            hardcover.lookup_book_by_isbn("9780975229804")

        self.assertEqual(raised.exception.provider, Sources.HARDCOVER.value)
        self.assertIsNone(raised.exception.status_code)

    @patch("app.providers.hardcover.services.api_request")
    def test_graphql_error_is_not_cached_as_a_missing_isbn(self, mock_api_request):
        mock_api_request.return_value = {"errors": [{"message": "temporarily unavailable"}]}

        self.assertIsNone(hardcover.lookup_book_by_isbn("9780975229804"))
        self.assertIsNone(hardcover.lookup_book_by_isbn("9780975229804"))

        self.assertEqual(mock_api_request.call_count, 2)
        self.assertIsNone(cache.get(f"isbn_{Sources.HARDCOVER.value}_9780975229804"))


class OpenLibraryISBNLookupTests(TestCase):
    def setUp(self):
        cache.clear()

    @patch("app.providers.openlibrary.services.api_request")
    def test_returns_exact_edition_and_caches_result(self, mock_api_request):
        mock_api_request.return_value = {
            "key": "/books/OL123M",
            "title": "A Fictional Edition",
            "covers": [9876],
            "number_of_pages": 384,
            "pagination": "x, 384 p.",
        }

        first = openlibrary.lookup_book_by_isbn(" 097522980x ")
        second = openlibrary.lookup_book_by_isbn("097522980X")

        self.assertEqual(first, second)
        self.assertEqual(
            first,
            {
                "media_id": "OL123M",
                "source": Sources.OPENLIBRARY.value,
                "media_type": MediaTypes.BOOK.value,
                "title": "A Fictional Edition",
                "image": "https://covers.openlibrary.org/b/id/9876-L.jpg",
                "max_progress": 384,
                "total_pages": 384,
                "matched_isbn": "097522980X",
            },
        )
        mock_api_request.assert_called_once_with(
            Sources.OPENLIBRARY.value,
            "GET",
            "https://openlibrary.org/isbn/097522980X.json",
            headers=openlibrary.headers,
        )

    @patch("app.providers.openlibrary.services.api_request")
    def test_ignores_free_form_pagination_when_page_count_is_missing(
        self,
        mock_api_request,
    ):
        mock_api_request.return_value = {
            "key": "/books/OL456M",
            "title": "A Book Without a Numeric Page Count",
            "pagination": "x, 384 p.",
        }

        result = openlibrary.lookup_book_by_isbn("9780975229804")

        self.assertIsNone(result["max_progress"])
        self.assertIsNone(result["total_pages"])
        self.assertEqual(result["image"], settings.IMG_NONE)

    @patch("app.providers.openlibrary.services.api_request")
    def test_404_is_negatively_cached(self, mock_api_request):
        response = MagicMock(status_code=requests.codes.not_found)
        mock_api_request.side_effect = requests.HTTPError(response=response)

        self.assertIsNone(openlibrary.lookup_book_by_isbn("9780975229804"))
        self.assertIsNone(openlibrary.lookup_book_by_isbn("9780975229804"))

        mock_api_request.assert_called_once()
        self.assertIs(
            cache.get(f"isbn_{Sources.OPENLIBRARY.value}_9780975229804"),
            False,
        )

    @patch("app.providers.openlibrary.services.api_request")
    def test_network_error_uses_provider_error_contract(self, mock_api_request):
        mock_api_request.side_effect = requests.ConnectionError("connection failed")

        with self.assertRaises(services.ProviderAPIError) as raised:
            openlibrary.lookup_book_by_isbn("9780975229804")

        self.assertEqual(raised.exception.provider, Sources.OPENLIBRARY.value)
        self.assertIsNone(raised.exception.status_code)

    @patch("app.providers.openlibrary.services.api_request")
    def test_response_without_an_edition_key_is_negatively_cached(self, mock_api_request):
        mock_api_request.return_value = {"title": "Incomplete Edition"}

        self.assertIsNone(openlibrary.lookup_book_by_isbn("9780975229804"))
        self.assertIsNone(openlibrary.lookup_book_by_isbn("9780975229804"))

        mock_api_request.assert_called_once()

