from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase

from api.services import media
from app.models import (
    CustomBackdropPreference,
    CustomPosterPreference,
    Item,
    MediaTypes,
    Sources,
)


class AnimeDetailEnrichmentTests(TestCase):
    """Verify MAL-first anime detail enrichment."""

    def setUp(self):
        cache.clear()

    @patch(
        "api.services.media.external_rating_payload",
        return_value={
            "external_ratings": [],
            "external_ratings_preparation": {"state": "ready"},
        },
    )
    @patch("api.services.media.anilist.anime")
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_detail_merges_anilist_without_overwriting_mal(
        self,
        metadata_mock,
        anilist_mock,
        _ratings_mock,
    ):
        metadata_mock.return_value = {
            "media_id": "16498",
            "source": "mal",
            "media_type": "anime",
            "title": "Shingeki no Kyojin",
            "display_title": None,
            "image": "https://img.example/mal.jpg",
            "synopsis": "MAL synopsis",
            "details": {"season": "Spring 2013", "episodes": 25},
            "posters": [
                {
                    "url": "https://img.example/mal.jpg",
                    "provider_name": "MyAnimeList",
                    "is_original": True,
                },
            ],
            "related": {
                "relations": [
                    {
                        "media_id": "100",
                        "source": "mal",
                        "media_type": "anime",
                        "title": "MAL Prequel",
                        "relation": "Prequel",
                    },
                ],
                "recommendations": [
                    {
                        "media_id": "6",
                        "source": "mal",
                        "media_type": "anime",
                        "title": "Recommendation",
                    },
                ],
            },
        }
        anilist_mock.return_value = {
            "display_title": "Attack on Titan",
            "source_url": "https://anilist.co/anime/16498",
            "backdrop": "https://img.example/banner.jpg",
            "posters": [
                {
                    "url": "https://img.example/anilist.jpg",
                    "provider_name": "AniList",
                },
            ],
            "backdrops": [
                {
                    "url": "https://img.example/banner.jpg",
                    "provider_name": "AniList",
                },
            ],
            "characters": [
                {
                    "person_id": "character:1",
                    "name": "Eren Yeager",
                    "role": "Main",
                    "image": "https://img.example/eren.jpg",
                },
            ],
            "cast": [
                {
                    "person_id": "110665",
                    "person_source": "anilist",
                    "name": "Yuki Kaji",
                    "character": "Eren Yeager",
                    "image": "https://img.example/kaji.jpg",
                },
            ],
            "rating_summary": {
                "average_score": 84,
                "rating_count": 200,
                "score_distribution": [
                    {"score": 80, "count": 120},
                    {"score": 90, "count": 80},
                ],
                "has_reviews": True,
                "url": "https://anilist.co/anime/16498",
            },
            "relations": [
                {
                    "media_id": "200",
                    "source": "mal",
                    "media_type": "manga",
                    "title": "Shingeki no Kyojin",
                    "display_title": "Attack on Titan",
                    "relation": "Source",
                    "image": "https://img.example/manga.jpg",
                },
                {
                    "media_id": "100",
                    "source": "mal",
                    "media_type": "anime",
                    "title": "AniList Prequel",
                    "display_title": "The Prequel",
                    "relation": "Prequel",
                },
            ],
        }

        result = media.media_detail(
            source=Sources.MAL.value,
            media_type=MediaTypes.ANIME.value,
            media_id="16498",
        )

        self.assertEqual(result["title"], "Shingeki no Kyojin")
        self.assertEqual(result["display_title"], "Attack on Titan")
        self.assertEqual(result["synopsis"], "MAL synopsis")
        self.assertEqual(result["backdrop_url"], "https://img.example/banner.jpg")
        self.assertEqual(result["cast"][0]["id"], "110665")
        self.assertEqual(result["cast"][0]["name"], "Yuki Kaji")
        self.assertEqual(result["cast"][0]["person_source"], "anilist")
        self.assertEqual(result["characters"][0]["role"], "Main")
        self.assertIsNone(result["characters"][0]["person_source"])
        self.assertEqual(result["details"]["anilist_rating"]["average_score"], 84)
        self.assertTrue(result["details"]["anilist_rating"]["has_reviews"])
        self.assertEqual(
            [section["id"] for section in result["related_sections"]],
            ["relations", "recommendations"],
        )
        relations = result["related_sections"][0]["items"]
        self.assertEqual([relation["relation"] for relation in relations], ["Source", "Prequel"])
        self.assertEqual(relations[0]["display_title"], "Attack on Titan")
        self.assertEqual(relations[1]["title"], "MAL Prequel")

    @patch(
        "api.services.media.external_rating_payload",
        return_value={
            "external_ratings": [],
            "external_ratings_preparation": {"state": "ready"},
        },
    )
    @patch("api.services.media.mal.anime_cast", return_value=[])
    @patch("api.services.media.anilist.anime", return_value={})
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_detail_still_returns_mal_when_anilist_has_no_data(
        self,
        metadata_mock,
        _anilist_mock,
        _cast_mock,
        _ratings_mock,
    ):
        metadata_mock.return_value = {
            "media_id": "1",
            "source": "mal",
            "media_type": "anime",
            "title": "Cowboy Bebop",
            "image": "https://img.example/bebop.jpg",
            "details": {"season": "Spring 1998"},
        }

        result = media.media_detail(
            source=Sources.MAL.value,
            media_type=MediaTypes.ANIME.value,
            media_id="1",
        )

        self.assertEqual(result["title"], "Cowboy Bebop")
        self.assertIsNone(result["backdrop_url"])
        self.assertEqual(result["cast"], [])
        self.assertEqual(result["characters"], [])
        self.assertNotIn("anilist_rating", result["details"])

    @patch("api.services.media.anilist.anime", return_value={})
    @patch("api.services.media.mal.anime_cast")
    def test_detail_uses_jikan_cast_when_anilist_is_unavailable(
        self,
        cast_mock,
        _anilist_mock,
    ):
        cast_mock.return_value = [
            {
                "person_id": "11",
                "person_source": "mal",
                "name": "Yuki Kaji",
                "character": "Eren Yeager",
            },
        ]

        result = media._enrich_anime_metadata(
            {
                "media_id": "16498",
                "source": "mal",
                "media_type": "anime",
                "title": "Shingeki no Kyojin",
            },
            Sources.MAL.value,
        )

        self.assertEqual(result["cast"][0]["person_id"], "11")
        self.assertEqual(result["cast"][0]["person_source"], "mal")


class AnimeArtworkTests(TestCase):
    """Verify anime uses the existing artwork preference flow."""

    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="anime-art",
            password="strong-password-123",
        )
        self.item = Item.objects.create(
            source=Sources.MAL.value,
            media_type=MediaTypes.ANIME.value,
            media_id="16498",
            title="Shingeki no Kyojin",
            image="https://img.example/mal.jpg",
        )

    @patch("api.services.media.anilist.anime")
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_anime_artwork_combines_role_correct_sources(
        self,
        metadata_mock,
        anilist_mock,
    ):
        metadata_mock.return_value = {
            "media_id": "16498",
            "title": "Shingeki no Kyojin",
            "image": self.item.image,
            "posters": [
                {
                    "url": self.item.image,
                    "provider_name": "MyAnimeList",
                    "is_original": True,
                },
            ],
        }
        anilist_mock.return_value = {
            "posters": [
                {
                    "url": "https://img.example/anilist.jpg",
                    "provider_name": "AniList",
                    "provider_url": "https://anilist.co/anime/16498",
                },
            ],
            "backdrop": "https://img.example/banner.jpg",
            "backdrops": [
                {
                    "url": "https://img.example/banner.jpg",
                    "provider_name": "AniList",
                    "provider_url": "https://anilist.co/anime/16498",
                },
            ],
        }

        posters = media.poster_options(
            source="mal",
            media_type="anime",
            media_id="16498",
            user=self.user,
        )["posters"]
        backdrops = media.backdrop_options(
            source="mal",
            media_type="anime",
            media_id="16498",
            user=self.user,
        )["backdrops"]

        self.assertEqual(
            [poster["provider_name"] for poster in posters],
            ["MyAnimeList", "AniList"],
        )
        self.assertEqual([backdrop["url"] for backdrop in backdrops], ["https://img.example/banner.jpg"])
        self.assertTrue(backdrops[0]["is_selected"])

    @patch("api.services.media.build_accent_palette", return_value={"accent": "#abcdef"})
    @patch("api.services.media.compute_and_store_poster_accent", return_value="#abcdef")
    def test_anime_artwork_preferences_use_existing_models(
        self,
        _accent_mock,
        _palette_mock,
    ):
        media.save_poster_preference(
            source="mal",
            media_type="anime",
            media_id="16498",
            poster_url="https://img.example/custom-poster.jpg",
            user=self.user,
        )
        media.save_backdrop_preference(
            source="mal",
            media_type="anime",
            media_id="16498",
            backdrop_url="https://img.example/custom-banner.jpg",
            user=self.user,
        )

        self.assertEqual(
            CustomPosterPreference.objects.get(user=self.user, item=self.item).custom_image_url,
            "https://img.example/custom-poster.jpg",
        )
        self.assertEqual(
            CustomBackdropPreference.objects.get(user=self.user, item=self.item).custom_image_url,
            "https://img.example/custom-banner.jpg",
        )
