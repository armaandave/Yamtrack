import json
from unittest.mock import MagicMock, patch

from django.core.cache import cache
from django.test import TestCase, override_settings

from app.providers import imdb


@override_settings(
    IMDB_API_KEY="licensed-api-key",
    IMDB_DATA_SET_ID="data-set-id",
    IMDB_REVISION_ID="revision-id",
    IMDB_ASSET_ID="asset-id",
    IMDB_AWS_REGION="us-east-1",
)
class IMDbProviderTests(TestCase):
    def setUp(self):
        cache.clear()

    @patch("app.providers.imdb._client")
    def test_title_rating_uses_official_api_and_caches_result(self, client_mock):
        client = MagicMock()
        client.send_api_asset.return_value = {
            "Body": json.dumps(
                {
                    "data": {
                        "title": {
                            "ratingsSummary": {
                                "aggregateRating": 8.7,
                                "voteCount": 12543,
                            },
                        },
                    },
                },
            ),
        }
        client_mock.return_value = client

        first = imdb.get_title_rating("tt1480055")
        second = imdb.get_title_rating("tt1480055")

        self.assertEqual(
            first,
            {
                "value": 8.7,
                "votes": 12543,
                "url": "https://www.imdb.com/title/tt1480055/",
            },
        )
        self.assertEqual(second, first)
        client.send_api_asset.assert_called_once()
        request = client.send_api_asset.call_args.kwargs
        self.assertEqual(request["DataSetId"], "data-set-id")
        self.assertEqual(request["RevisionId"], "revision-id")
        self.assertEqual(request["AssetId"], "asset-id")
        self.assertEqual(request["RequestHeaders"], {"x-api-key": "licensed-api-key"})
        self.assertIn('title(id: "tt1480055")', json.loads(request["Body"])["query"])

    @patch("app.providers.imdb._client")
    def test_missing_rating_and_provider_failures_fall_back_to_none(self, client_mock):
        client = MagicMock()
        client.send_api_asset.return_value = {
            "Body": json.dumps({"data": {"title": {"ratingsSummary": None}}}),
        }
        client_mock.return_value = client

        self.assertIsNone(imdb.get_title_rating("tt0000001"))

        cache.clear()
        client.send_api_asset.side_effect = RuntimeError("temporary outage")
        self.assertIsNone(imdb.get_title_rating("tt0000002"))

    @override_settings(IMDB_API_KEY="")
    @patch("app.providers.imdb._client")
    def test_unconfigured_or_invalid_ids_do_not_call_aws(self, client_mock):
        self.assertIsNone(imdb.get_title_rating("tt1480055"))
        self.assertIsNone(imdb.get_title_rating('tt1" } malicious'))
        client_mock.assert_not_called()
