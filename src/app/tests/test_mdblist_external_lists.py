from unittest.mock import call, patch

from django.test import SimpleTestCase, override_settings

from app.providers import mdblist


@override_settings(MDBLIST_API="test-key")
class MDBListExternalListsTests(SimpleTestCase):
    """MDBList external-list pagination contract."""

    @patch("app.providers.mdblist.services.api_request")
    def test_items_follow_cursor_and_preserve_media_types(self, api_request):
        api_request.side_effect = [
            {
                "movies": [{"id": 1, "title": "Movie"}],
                "shows": [],
                "pagination": {"next_cursor": "next-page"},
            },
            {
                "movies": [],
                "shows": [{"id": 2, "title": "Show"}],
            },
        ]

        items = mdblist.get_external_list_items(155837)

        self.assertEqual(
            [(item["id"], item["spine_media_type"]) for item in items],
            [(1, "movie"), (2, "tv")],
        )
        self.assertEqual(
            api_request.call_args_list,
            [
                call(
                    "mdblist",
                    "GET",
                    "https://api.mdblist.com/external/lists/155837/items",
                    params={
                        "apikey": "test-key",
                        "append_to_response": "poster",
                        "limit": 1000,
                    },
                ),
                call(
                    "mdblist",
                    "GET",
                    "https://api.mdblist.com/external/lists/155837/items",
                    params={
                        "apikey": "test-key",
                        "append_to_response": "poster",
                        "limit": 1000,
                        "cursor": "next-page",
                    },
                ),
            ],
        )

    @patch("app.providers.mdblist.services.api_request")
    def test_metadata_unwraps_live_singleton_shape(self, api_request):
        api_request.return_value = [{"id": 155837, "name": "Featured"}]

        self.assertEqual(mdblist.get_external_list(155837)["name"], "Featured")
