from unittest.mock import Mock, patch

from django.test import SimpleTestCase, override_settings

from app.providers import googlebooks


@override_settings(GOOGLE_BOOKS_API_KEY="test-key", REQUEST_TIMEOUT=10)
class GoogleBooksProviderTests(SimpleTestCase):
    isbn13 = "9780439708180"
    isbn10 = "0439708184"

    def response(self, items, cache_control="private, max-age=0"):
        response = Mock()
        response.headers = {"Cache-Control": cache_control}
        response.json.return_value = {"items": items}
        return response

    def item(self, *, identifiers=None, volume_id="hp1"):
        return {
            "id": volume_id,
            "volumeInfo": {
                "title": "Harry Potter and the Sorcerer's Stone",
                "subtitle": "Book One",
                "authors": ["J. K. Rowling"],
                "publisher": "Scholastic",
                "publishedDate": "1998-09-01",
                "description": "<b>A young wizard</b> begins school.",
                "industryIdentifiers": identifiers
                or [
                    {"type": "ISBN_10", "identifier": self.isbn10},
                    {"type": "ISBN_13", "identifier": self.isbn13},
                ],
                "pageCount": 309,
                "categories": ["Juvenile Fiction"],
                "averageRating": 4.5,
                "ratingsCount": 125,
                "maturityRating": "NOT_MATURE",
                "imageLinks": {
                    "thumbnail": "http://books.google.com/thumb.jpg",
                    "extraLarge": "http://books.google.com/extra-large.jpg",
                },
                "language": "en",
                "canonicalVolumeLink": "http://books.google.com/books?id=hp1",
            },
            "saleInfo": {
                "country": "US",
                "saleability": "FOR_SALE",
                "retailPrice": {"amount": 12.99, "currencyCode": "USD"},
            },
        }

    @patch("app.providers.googlebooks.cache.get", return_value=None)
    @patch("app.providers.googlebooks.cache.set")
    @patch("app.providers.googlebooks.services.session.get")
    def test_exact_equivalent_isbns_return_one_allowlisted_volume(
        self,
        get_mock,
        cache_set_mock,
        _cache_get_mock,
    ):
        get_mock.return_value = self.response(
            [self.item()],
            "public, max-age=120",
        )

        result = googlebooks.lookup_volume([self.isbn10, self.isbn13])

        self.assertEqual(result["matched_isbn"], self.isbn13)
        self.assertEqual(result["description"], "A young wizard begins school.")
        self.assertEqual(result["cover_url"], "https://books.google.com/extra-large.jpg")
        self.assertEqual(result["rating"], {"value": "4.5", "count": 125})
        self.assertEqual(
            result["price"],
            {"amount": "12.99", "currency": "USD", "country": "US"},
        )
        self.assertNotIn("previewLink", result)
        self.assertNotIn("buyLink", result)
        get_mock.assert_called_once()
        self.assertEqual(get_mock.call_args.kwargs["params"]["q"], f"isbn:{self.isbn13}")
        cache_set_mock.assert_called_once_with(
            f"google-books:v1:{self.isbn13}",
            result,
            120,
        )

    @patch("app.providers.googlebooks.cache.get", return_value=None)
    @patch("app.providers.googlebooks.cache.set")
    @patch("app.providers.googlebooks.services.session.get")
    def test_uncacheable_response_is_not_stored(
        self,
        get_mock,
        cache_set_mock,
        _cache_get_mock,
    ):
        get_mock.return_value = self.response([self.item()])

        self.assertIsNotNone(googlebooks.lookup_volume([self.isbn13]))
        cache_set_mock.assert_not_called()

    @patch("app.providers.googlebooks.cache.get", return_value=None)
    @patch("app.providers.googlebooks.services.session.get")
    def test_missing_explicit_isbn_is_rejected(self, get_mock, _cache_get_mock):
        get_mock.return_value = self.response(
            [
                self.item(
                    identifiers=[
                        {"type": "OTHER", "identifier": "UOM:39015047305043"},
                    ],
                ),
            ],
        )

        self.assertIsNone(googlebooks.lookup_volume([self.isbn13]))

    @patch("app.providers.googlebooks.cache.get", return_value=None)
    @patch("app.providers.googlebooks.services.session.get")
    def test_other_identifier_is_rejected_even_with_matching_isbn(
        self,
        get_mock,
        _cache_get_mock,
    ):
        get_mock.return_value = self.response(
            [
                self.item(
                    identifiers=[
                        {"type": "ISBN_13", "identifier": self.isbn13},
                        {"type": "OTHER", "identifier": "unexpected"},
                    ],
                ),
            ],
        )

        self.assertIsNone(googlebooks.lookup_volume([self.isbn13]))

    @patch("app.providers.googlebooks.cache.get", return_value=None)
    @patch("app.providers.googlebooks.services.session.get")
    def test_conflicting_or_duplicate_exact_matches_are_rejected(
        self,
        get_mock,
        _cache_get_mock,
    ):
        conflicting = self.item(
            identifiers=[
                {"type": "ISBN_13", "identifier": self.isbn13},
                {"type": "ISBN_13", "identifier": "9780553804577"},
            ],
        )
        get_mock.return_value = self.response([conflicting])
        self.assertIsNone(googlebooks.lookup_volume([self.isbn13]))

        get_mock.return_value = self.response(
            [self.item(volume_id="one"), self.item(volume_id="two")],
        )
        self.assertIsNone(googlebooks.lookup_volume([self.isbn13]))

    @patch("app.providers.googlebooks.services.session.get")
    def test_invalid_or_ambiguous_primary_isbns_skip_the_request(self, get_mock):
        self.assertIsNone(googlebooks.lookup_volume(["not-an-isbn"]))
        self.assertIsNone(
            googlebooks.lookup_volume([self.isbn13, "9780553804577"]),
        )
        self.assertIsNone(
            googlebooks.lookup_volume([self.isbn13, "9780439708181"]),
        )
        get_mock.assert_not_called()

    @override_settings(GOOGLE_BOOKS_API_KEY="")
    @patch("app.providers.googlebooks.services.session.get")
    def test_missing_api_key_disables_lookup(self, get_mock):
        self.assertIsNone(googlebooks.lookup_volume([self.isbn13]))
        get_mock.assert_not_called()

    @patch("app.providers.googlebooks.cache.get", return_value=None)
    @patch("app.providers.googlebooks.services.session.get")
    def test_malformed_items_are_ignored(self, get_mock, _cache_get_mock):
        response = self.response([])
        response.json.return_value = {"items": {"unexpected": "shape"}}
        get_mock.return_value = response

        self.assertIsNone(googlebooks.lookup_volume([self.isbn13]))


class GoogleBooksISBNTests(SimpleTestCase):
    def test_isbn_10_and_13_share_one_identity(self):
        self.assertEqual(
            googlebooks.isbn13_identity("0-439-70818-4"),
            "9780439708180",
        )
        self.assertEqual(
            googlebooks.edition_identity(["0-439-70818-4", "978-0-439-70818-0"]),
            "9780439708180",
        )
        self.assertIsNone(googlebooks.isbn13_identity("9780439708181"))
