from unittest.mock import patch

from django.test import SimpleTestCase

from api.services import media
from app.models import MediaTypes, Sources


class DiscoverMediaCacheTests(SimpleTestCase):
    """Verify provider discovery cache recovery."""

    @patch("api.services.media.cache")
    @patch("api.services.media.provider_services.discover")
    def test_empty_anime_and_manga_pages_use_short_ttl(self, discover, cache):
        cache.get.return_value = None
        discover.return_value = {
            "per_page": 25,
            "total_results": 0,
            "results": [],
        }

        for media_type in (MediaTypes.ANIME.value, MediaTypes.MANGA.value):
            with self.subTest(media_type=media_type):
                media.discover_media(
                    media_type=media_type,
                    source=Sources.MAL.value,
                    genre="Action",
                )

                self.assertEqual(cache.set.call_args.args[2], media.DISCOVER_EMPTY_TTL)
                cache.set.reset_mock()

    @patch("api.services.media.cache")
    @patch("api.services.media.provider_services.discover")
    def test_other_empty_discovery_pages_keep_six_hour_ttl(self, discover, cache):
        cache.get.return_value = None
        discover.return_value = {"results": [], "total_results": 0}

        media.discover_media(
            media_type=MediaTypes.MOVIE.value,
            source=Sources.TMDB.value,
            genre="Action",
        )

        self.assertEqual(cache.set.call_args.args[2], media.DISCOVER_TTL)

    @patch("api.services.media.media_summary_from_provider", return_value={})
    @patch("api.services.media.cache")
    @patch("api.services.media.provider_services.discover")
    def test_nonempty_anime_and_manga_pages_keep_six_hour_ttl(
        self,
        discover,
        cache,
        _summary,
    ):
        cache.get.return_value = None
        discover.side_effect = lambda media_type, **_kwargs: {
            "per_page": 25,
            "total_results": 1,
            "results": [
                {
                    "media_id": "1",
                    "media_type": media_type,
                    "source": Sources.MAL.value,
                    "title": "Title",
                },
            ],
        }

        for media_type in (MediaTypes.ANIME.value, MediaTypes.MANGA.value):
            with self.subTest(media_type=media_type):
                media.discover_media(
                    media_type=media_type,
                    source=Sources.MAL.value,
                    genre="Action",
                )

                self.assertEqual(cache.set.call_args.args[2], media.DISCOVER_TTL)
                cache.set.reset_mock()

    @patch("api.services.media.cache")
    @patch(
        "api.services.media.provider_services.discover",
        side_effect=RuntimeError("provider failed"),
    )
    def test_provider_exceptions_are_not_cached(self, _discover, cache):
        cache.get.return_value = None

        for media_type in (MediaTypes.ANIME.value, MediaTypes.MANGA.value):
            with (
                self.subTest(media_type=media_type),
                self.assertRaisesMessage(RuntimeError, "provider failed"),
            ):
                media.discover_media(
                    media_type=media_type,
                    source=Sources.MAL.value,
                    genre="Action",
                )

        cache.set.assert_not_called()
