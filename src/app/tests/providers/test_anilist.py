from unittest.mock import patch

import requests
from django.core.cache import cache
from django.test import TestCase

from app.providers import anilist, mal, mangaupdates


class AniListProviderTests(TestCase):
    def setUp(self):
        cache.clear()

    @patch("app.providers.anilist.services.api_request")
    def test_anime_normalizes_artwork_relations_rating_and_japanese_cast(
        self,
        request_mock,
    ):
        request_mock.return_value = {
            "data": {
                "Media": {
                    "id": 16498,
                    "idMal": 16498,
                    "siteUrl": "https://anilist.co/anime/16498",
                    "title": {
                        "english": "Attack on Titan",
                        "romaji": "Shingeki no Kyojin",
                        "native": "進撃の巨人",
                    },
                    "coverImage": {
                        "extraLarge": "https://img.example/cover-xl.jpg",
                        "large": "https://img.example/cover.jpg",
                        "medium": "https://img.example/cover-thumb.jpg",
                        "color": "#4a5b6c",
                    },
                    "bannerImage": "https://img.example/banner.jpg",
                    "averageScore": 84,
                    "stats": {
                        "scoreDistribution": [
                            {"score": 80, "amount": 120},
                            {"score": 90, "amount": 80},
                        ],
                    },
                    "relations": {
                        "edges": [
                            {
                                "relationType": "PREQUEL",
                                "node": {
                                    "id": 100,
                                    "idMal": 100,
                                    "type": "ANIME",
                                    "format": "TV",
                                    "siteUrl": "https://anilist.co/anime/100",
                                    "title": {
                                        "english": "The Prequel",
                                        "romaji": "Prequel",
                                        "native": None,
                                    },
                                    "coverImage": {
                                        "extraLarge": None,
                                        "large": "https://img.example/prequel.jpg",
                                        "medium": None,
                                    },
                                    "startDate": {"year": 2012},
                                },
                            },
                            {
                                "relationType": "SOURCE",
                                "node": {
                                    "id": 200,
                                    "idMal": 200,
                                    "type": "MANGA",
                                    "format": "MANGA",
                                    "siteUrl": "https://anilist.co/manga/200",
                                    "title": {
                                        "english": "Attack on Titan",
                                        "romaji": "Shingeki no Kyojin",
                                        "native": None,
                                    },
                                    "coverImage": {
                                        "extraLarge": None,
                                        "large": "https://img.example/manga.jpg",
                                        "medium": None,
                                    },
                                    "startDate": {"year": 2009},
                                },
                            },
                        ],
                    },
                    "characters": {
                        "edges": [
                            {
                                "role": "MAIN",
                                "node": {
                                    "id": 1,
                                    "name": {"full": "Eren Yeager", "native": None},
                                    "image": {
                                        "large": "https://img.example/eren.jpg",
                                        "medium": None,
                                    },
                                },
                                "voiceActors": [
                                    {
                                        "id": 10,
                                        "languageV2": "English",
                                        "name": {"full": "English Actor", "native": None},
                                        "image": {"large": None, "medium": None},
                                    },
                                    {
                                        "id": 11,
                                        "languageV2": "Japanese",
                                        "name": {"full": "Yuki Kaji", "native": None},
                                        "image": {
                                            "large": "https://img.example/kaji.jpg",
                                            "medium": None,
                                        },
                                    },
                                ],
                            },
                            {
                                "role": "SUPPORTING",
                                "node": {
                                    "id": 2,
                                    "name": {"full": "Another Character", "native": None},
                                    "image": {
                                        "large": "https://img.example/another.jpg",
                                        "medium": None,
                                    },
                                },
                                "voiceActors": [
                                    {
                                        "id": 11,
                                        "languageV2": "Japanese",
                                        "name": {"full": "Yuki Kaji", "native": None},
                                        "image": {
                                            "large": "https://img.example/kaji.jpg",
                                            "medium": None,
                                        },
                                    },
                                ],
                            },
                        ],
                    },
                },
            },
        }

        result = anilist.anime("16498")

        self.assertEqual(result["display_title"], "Attack on Titan")
        self.assertEqual(result["backdrop"], "https://img.example/banner.jpg")
        self.assertEqual(result["rating"]["value"], 84)
        self.assertEqual(result["rating"]["vote_count"], 200)
        self.assertEqual(result["relations"][0]["media_type"], "anime")
        self.assertEqual(result["relations"][1]["media_type"], "manga")
        self.assertEqual(result["characters"][0]["role"], "Main")
        self.assertNotIn("person_source", result["characters"][0])
        self.assertEqual(len(result["cast"]), 1)
        self.assertEqual(result["cast"][0]["person_id"], "11")
        self.assertEqual(result["cast"][0]["person_source"], "anilist")
        self.assertEqual(result["cast"][0]["name"], "Yuki Kaji")
        self.assertEqual(
            result["cast"][0]["character"],
            "Eren Yeager · Another Character",
        )
        request_mock.assert_called_once()

    @patch("app.providers.anilist.services.api_request")
    def test_anime_uses_stale_success_when_request_fails(self, request_mock):
        stale = {"display_title": "Cached Anime"}
        cache.set(
            f"anilist:{anilist.CACHE_VERSION}:anime:1:stale",
            stale,
            anilist.STALE_TTL,
        )
        request_mock.side_effect = requests.Timeout("down")

        self.assertEqual(anilist.anime("1"), stale)
        self.assertEqual(anilist.anime("1"), stale)
        request_mock.assert_called_once()

    @patch("app.providers.anilist.services.api_request")
    def test_anime_strict_mode_raises_without_stale_data(self, request_mock):
        request_mock.side_effect = requests.Timeout("down")

        with self.assertRaises(requests.Timeout):
            anilist.anime("1", raise_errors=True)

    @patch("app.providers.anilist.services.api_request")
    def test_anime_ignores_malformed_payload_without_breaking_detail(
        self,
        request_mock,
    ):
        request_mock.return_value = {
            "data": {
                "Media": {
                    "id": 1,
                    "title": {},
                    "characters": {"edges": [None]},
                },
            },
        }

        self.assertEqual(anilist.anime("1"), {})

    @patch("app.providers.anilist.services.api_request")
    def test_manga_normalizes_banner_characters_staff_relations_and_rating(
        self,
        request_mock,
    ):
        request_mock.return_value = {
            "data": {
                "Media": {
                    "id": 30013,
                    "idMal": 23390,
                    "siteUrl": "https://anilist.co/manga/30013",
                    "title": {
                        "english": "Attack on Titan",
                        "romaji": "Shingeki no Kyojin",
                        "native": "進撃の巨人",
                    },
                    "coverImage": {
                        "extraLarge": "https://img.example/manga-cover.jpg",
                        "medium": "https://img.example/manga-thumb.jpg",
                    },
                    "bannerImage": "https://img.example/manga-banner.jpg",
                    "averageScore": 85,
                    "stats": {
                        "scoreDistribution": [
                            {"score": 80, "amount": 70},
                            {"score": 90, "amount": 30},
                        ],
                    },
                    "relations": {
                        "edges": [
                            {
                                "relationType": "ADAPTATION",
                                "node": {
                                    "id": 16498,
                                    "idMal": 16498,
                                    "type": "ANIME",
                                    "siteUrl": "https://anilist.co/anime/16498",
                                    "title": {
                                        "english": "Attack on Titan",
                                        "romaji": "Shingeki no Kyojin",
                                    },
                                    "coverImage": {
                                        "large": "https://img.example/anime.jpg",
                                    },
                                    "startDate": {"year": 2013},
                                },
                            },
                        ],
                    },
                    "characters": {
                        "edges": [
                            {
                                "role": "MAIN",
                                "node": {
                                    "id": 1,
                                    "name": {"full": "Eren Yeager"},
                                    "image": {
                                        "large": "https://img.example/eren.jpg",
                                    },
                                },
                            },
                        ],
                    },
                    "staff": {
                        "edges": [
                            {
                                "role": "Story & Art",
                                "node": {
                                    "id": 2,
                                    "name": {"full": "Hajime Isayama"},
                                    "image": {
                                        "large": "https://img.example/isayama.jpg",
                                    },
                                },
                            },
                        ],
                    },
                    "recommendations": {"nodes": []},
                },
            },
        }

        result = anilist.manga("23390")

        self.assertEqual(result["display_title"], "Attack on Titan")
        self.assertEqual(result["backdrop"], "https://img.example/manga-banner.jpg")
        self.assertEqual(result["rating"]["value"], 85)
        self.assertEqual(result["rating"]["vote_count"], 100)
        self.assertEqual(result["characters"][0]["role"], "Main")
        self.assertEqual(result["creators"][0]["role"], "Story & Art")
        self.assertEqual(result["creators"][0]["person_source"], "anilist")
        self.assertEqual(result["creators"][0]["person_id"], "2")
        self.assertEqual(result["relations"][0]["media_type"], "anime")
        self.assertEqual(result["relations"][0]["relation"], "Adaptation")

    @patch("app.providers.anilist.services.api_request")
    def test_person_page_normalizes_profile_and_mal_manga_credits(
        self,
        request_mock,
    ):
        request_mock.return_value = {
            "data": {
                "Staff": {
                    "id": 106705,
                    "name": {
                        "full": "Hajime Isayama",
                        "native": "諫山創",
                        "alternative": [],
                    },
                    "image": {"large": "https://img.example/isayama.jpg"},
                    "description": "<b>Mangaka</b> and [creator](https://example.com).",
                    "primaryOccupations": ["Mangaka"],
                    "dateOfBirth": {"year": 1986, "month": 8, "day": 29},
                    "dateOfDeath": {},
                    "homeTown": "Oita, Japan",
                    "favourites": 6785,
                    "staffMedia": {
                        "pageInfo": {"hasNextPage": False},
                        "edges": [
                            {
                                "staffRole": "Story & Art",
                                "node": {
                                    "id": 53390,
                                    "idMal": 23390,
                                    "siteUrl": "https://anilist.co/manga/53390",
                                    "title": {
                                        "english": "Attack on Titan",
                                        "romaji": "Shingeki no Kyojin",
                                    },
                                    "coverImage": {
                                        "extraLarge": "https://img.example/aot.jpg",
                                    },
                                    "startDate": {
                                        "year": 2009,
                                        "month": 9,
                                        "day": 9,
                                    },
                                    "countryOfOrigin": "JP",
                                    "genres": ["Action"],
                                    "averageScore": 84,
                                    "popularity": 225000,
                                },
                            },
                            {
                                "staffRole": "Story",
                                "node": {
                                    "id": 999,
                                    "idMal": None,
                                    "title": {"romaji": "AniList-only manga"},
                                },
                            },
                        ],
                    },
                },
            },
        }

        result = anilist.person_page("106705")

        self.assertEqual(result["name"], "Hajime Isayama")
        self.assertEqual(result["biography"], "Mangaka and creator.")
        self.assertEqual(result["known_for_department"], "Mangaka")
        self.assertEqual(result["birth_date"], "1986-08-29")
        self.assertEqual(result["place_of_birth"], "Oita, Japan")
        self.assertEqual(len(result["credits"]), 1)
        self.assertEqual(result["credits"][0]["source"], "mal")
        self.assertEqual(result["credits"][0]["media_id"], "23390")
        self.assertEqual(result["credits"][0]["credit_roles"], ["Story & Art"])
        self.assertEqual(result["credits"][0]["languages"], ["Japanese"])

    @patch("app.providers.anilist.services.api_request")
    def test_person_page_paginates_and_merges_anime_voice_and_staff_credits(
        self,
        request_mock,
    ):
        def staff_payload(*, has_next, staff_edges, voice_edges):
            return {
                "data": {
                    "Staff": {
                        "id": 110665,
                        "name": {
                            "full": "Yuki Kaji",
                            "native": "梶裕貴",
                            "alternative": ["Kaji Yuki"],
                        },
                        "image": {"large": "https://img.example/kaji.jpg"},
                        "description": "Japanese voice actor.",
                        "primaryOccupations": ["Voice Actor"],
                        "dateOfBirth": {"year": 1985, "month": 9, "day": 3},
                        "dateOfDeath": {},
                        "homeTown": "Tokyo, Japan",
                        "favourites": 10000,
                        "mangaStaffMedia": {
                            "pageInfo": {"hasNextPage": False},
                            "edges": [],
                        },
                        "animeStaffMedia": {
                            "pageInfo": {"hasNextPage": has_next},
                            "edges": staff_edges,
                        },
                        "animeCharacterMedia": {
                            "pageInfo": {"hasNextPage": has_next},
                            "edges": voice_edges,
                        },
                    },
                },
            }

        attack_on_titan = {
            "id": 16498,
            "idMal": 16498,
            "title": {
                "english": "Attack on Titan",
                "romaji": "Shingeki no Kyojin",
            },
            "coverImage": {"large": "https://img.example/aot.jpg"},
            "startDate": {"year": 2013, "month": 4, "day": 7},
            "countryOfOrigin": "JP",
            "genres": ["Action"],
            "averageScore": 84,
            "popularity": 400000,
        }
        blue_lock = {
            "id": 137822,
            "idMal": 49596,
            "title": {"english": "Blue Lock", "romaji": "Blue Lock"},
            "coverImage": {"large": "https://img.example/blue-lock.jpg"},
            "startDate": {"year": 2022, "month": 10, "day": 9},
            "countryOfOrigin": "JP",
            "genres": ["Sports"],
            "averageScore": 80,
            "popularity": 200000,
        }
        request_mock.side_effect = [
            staff_payload(
                has_next=True,
                staff_edges=[
                    {"staffRole": "Theme Song Performance", "node": attack_on_titan},
                ],
                voice_edges=[
                    {"characters": [{"id": 1}], "node": attack_on_titan},
                ],
            ),
            staff_payload(
                has_next=False,
                staff_edges=[
                    {"staffRole": "Key Animation", "node": attack_on_titan},
                ],
                voice_edges=[
                    {"characters": [{"id": 2}], "node": blue_lock},
                    {
                        "characters": [{"id": 3}],
                        "node": {
                            "id": 999,
                            "idMal": None,
                            "title": {"romaji": "AniList only"},
                        },
                    },
                ],
            ),
        ]

        result = anilist.person_page("110665")

        self.assertEqual(request_mock.call_count, 2)
        self.assertEqual(result["alternative_names"], ["梶裕貴", "Kaji Yuki"])
        self.assertEqual(result["known_for_department"], "Voice Actor")
        self.assertEqual(len(result["credits"]), 2)
        attack_credit = result["credits"][0]
        self.assertEqual(attack_credit["media_type"], "anime")
        self.assertEqual(attack_credit["source"], "mal")
        self.assertEqual(attack_credit["media_id"], "16498")
        self.assertEqual(
            attack_credit["credit_roles"],
            ["Theme Song Performance", "Key Animation", "Voice Actor"],
        )
        self.assertEqual(result["credits"][1]["media_id"], "49596")
        self.assertEqual(result["credits"][1]["credit_roles"], ["Voice Actor"])


class MALAnimeMetadataTests(TestCase):
    def setUp(self):
        cache.clear()

    @patch("app.providers.mal.services.api_request")
    def test_anime_keeps_english_title_pictures_and_relation_type(
        self,
        request_mock,
    ):
        request_mock.return_value = {
            "id": 16498,
            "title": "Shingeki no Kyojin",
            "alternative_titles": {"en": "Attack on Titan"},
            "main_picture": {
                "large": "https://img.example/main.jpg",
                "medium": "https://img.example/main-thumb.jpg",
            },
            "pictures": [
                {
                    "large": "https://img.example/alternate.jpg",
                    "medium": "https://img.example/alternate-thumb.jpg",
                },
            ],
            "media_type": "tv",
            "start_date": "2013-04-07",
            "end_date": "2013-09-29",
            "synopsis": "MAL synopsis",
            "status": "finished_airing",
            "genres": [{"id": 1, "name": "Action"}],
            "mean": 8.5,
            "num_scoring_users": 100,
            "num_episodes": 25,
            "average_episode_duration": 1440,
            "studios": [{"id": 1, "name": "Wit Studio"}],
            "start_season": {"year": 2013, "season": "spring"},
            "source": "manga",
            "related_anime": [
                {
                    "node": {
                        "id": 100,
                        "title": "The Prequel",
                        "main_picture": {
                            "large": "https://img.example/prequel.jpg",
                        },
                    },
                    "relation_type": "prequel",
                    "relation_type_formatted": "Prequel",
                },
            ],
            "recommendations": [],
        }

        result = mal.anime("16498")

        self.assertEqual(result["title"], "Shingeki no Kyojin")
        self.assertEqual(result["display_title"], "Attack on Titan")
        self.assertEqual(len(result["posters"]), 2)
        self.assertEqual(result["related"]["relations"][0]["relation"], "Prequel")
        fields = request_mock.call_args.kwargs["params"]["fields"]
        self.assertIn("alternative_titles", fields)
        self.assertIn("pictures", fields)

    @patch("app.providers.mal.services.api_request")
    def test_manga_keeps_english_title_pictures_creators_and_mixed_relations(
        self,
        request_mock,
    ):
        request_mock.return_value = {
            "id": 23390,
            "title": "Shingeki no Kyojin",
            "alternative_titles": {"en": "Attack on Titan"},
            "main_picture": {"large": "https://img.example/main.jpg"},
            "pictures": [{"large": "https://img.example/alternate.jpg"}],
            "media_type": "manga",
            "start_date": "2009-09-09",
            "end_date": "2021-04-09",
            "synopsis": "MAL synopsis",
            "status": "finished",
            "genres": [{"name": "Action"}],
            "mean": 8.6,
            "num_scoring_users": 1000,
            "num_chapters": 141,
            "num_volumes": 34,
            "authors": [
                {
                    "node": {
                        "id": 11705,
                        "first_name": "Hajime",
                        "last_name": "Isayama",
                    },
                    "role": "Story & Art",
                },
            ],
            "serialization": [{"node": {"name": "Bessatsu Shounen Magazine"}}],
            "related_manga": [],
            "related_anime": [
                {
                    "node": {
                        "id": 16498,
                        "title": "Shingeki no Kyojin",
                        "main_picture": {"large": "https://img.example/anime.jpg"},
                    },
                    "relation_type_formatted": "Adaptation",
                },
            ],
            "recommendations": [],
        }

        result = mal.manga("23390")

        self.assertEqual(result["display_title"], "Attack on Titan")
        self.assertEqual(result["details"]["number_of_volumes"], 34)
        self.assertEqual(result["creators"][0]["name"], "Hajime Isayama")
        self.assertEqual(result["related"]["relations"][0]["media_type"], "anime")
        self.assertEqual(result["related"]["relations"][0]["relation"], "Adaptation")
        self.assertEqual(len(result["posters"]), 2)
        fields = request_mock.call_args.kwargs["params"]["fields"]
        for field in ("num_volumes", "authors", "related_anime", "related_manga"):
            self.assertIn(field, fields)

    @patch("app.providers.mal.services.api_request")
    def test_person_page_normalizes_jikan_mal_profile(self, request_mock):
        request_mock.return_value = {
            "data": {
                "mal_id": 11705,
                "name": "Hajime Isayama",
                "images": {
                    "jpg": {"image_url": "https://img.example/isayama.jpg"},
                },
                "birthday": "1986-08-29T00:00:00+00:00",
                "about": "<b>Manga creator</b>",
                "favorites": 100,
                "manga": [
                    {
                        "position": "Story & Art",
                        "manga": {
                            "mal_id": 23390,
                            "title": "Shingeki no Kyojin",
                            "url": "https://myanimelist.net/manga/23390",
                            "images": {
                                "jpg": {
                                    "large_image_url": "https://img.example/aot.jpg",
                                },
                            },
                        },
                    },
                ],
                "anime": [
                    {
                        "position": "Theme Song Performance",
                        "anime": {
                            "mal_id": 16498,
                            "title": "Shingeki no Kyojin",
                            "title_english": "Attack on Titan",
                            "url": "https://myanimelist.net/anime/16498",
                            "images": {
                                "jpg": {
                                    "large_image_url": "https://img.example/anime.jpg",
                                },
                            },
                        },
                    },
                ],
                "voices": [
                    {
                        "role": "Main",
                        "anime": {
                            "mal_id": 16498,
                            "title": "Shingeki no Kyojin",
                            "title_english": "Attack on Titan",
                            "url": "https://myanimelist.net/anime/16498",
                            "images": {
                                "jpg": {
                                    "large_image_url": "https://img.example/anime.jpg",
                                },
                            },
                        },
                    },
                ],
            },
        }

        result = mal.person_page("11705")

        self.assertEqual(result["person_id"], "11705")
        self.assertEqual(result["biography"], "Manga creator")
        self.assertEqual(len(result["credits"]), 2)
        self.assertEqual(result["credits"][0]["media_id"], "23390")
        self.assertEqual(result["credits"][0]["credit_roles"], ["Story & Art"])
        self.assertEqual(result["credits"][1]["media_type"], "anime")
        self.assertEqual(result["credits"][1]["media_id"], "16498")
        self.assertEqual(
            result["credits"][1]["credit_roles"],
            ["Theme Song Performance", "Voice Actor"],
        )
        self.assertEqual(result["known_for_department"], "Voice Actor")

    @patch("app.providers.mal.services.api_request")
    def test_anime_cast_uses_japanese_voice_actor_and_merges_characters(
        self,
        request_mock,
    ):
        request_mock.return_value = {
            "data": [
                {
                    "character": {"mal_id": 1, "name": "Eren Yeager"},
                    "voice_actors": [
                        {
                            "language": "English",
                            "person": {"mal_id": 10, "name": "English Actor"},
                        },
                        {
                            "language": "Japanese",
                            "person": {
                                "mal_id": 11,
                                "name": "Yuki Kaji",
                                "images": {
                                    "jpg": {
                                        "image_url": "https://img.example/kaji.jpg",
                                    },
                                },
                            },
                        },
                    ],
                },
                {
                    "character": {"mal_id": 2, "name": "Another Character"},
                    "voice_actors": [
                        {
                            "language": "Japanese",
                            "person": {
                                "mal_id": 11,
                                "name": "Yuki Kaji",
                                "images": {
                                    "jpg": {
                                        "image_url": "https://img.example/kaji.jpg",
                                    },
                                },
                            },
                        },
                    ],
                },
            ],
        }

        result = mal.anime_cast("16498")

        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["person_id"], "11")
        self.assertEqual(result[0]["person_source"], "mal")
        self.assertEqual(result[0]["character"], "Eren Yeager · Another Character")

    @patch("app.providers.mal.services.api_request")
    def test_anime_cast_uses_stale_data_and_failure_marker(self, request_mock):
        stale = [{"person_id": "11", "person_source": "mal", "name": "Yuki Kaji"}]
        cache.set(
            "mal:v1:anime-cast:16498:stale",
            stale,
            mal.ANIME_CAST_STALE_TTL,
        )
        request_mock.side_effect = requests.Timeout("down")

        self.assertEqual(mal.anime_cast("16498"), stale)
        self.assertEqual(mal.anime_cast("16498"), stale)
        request_mock.assert_called_once()


class MangaUpdatesPersonTests(TestCase):
    def setUp(self):
        cache.clear()

    @patch("app.providers.mangaupdates.services.api_request")
    def test_person_page_normalizes_author_and_series(self, request_mock):
        request_mock.side_effect = [
            {
                "id": 56479861123,
                "name": "ISAYAMA Hajime",
                "image": {
                    "url": {
                        "original": "https://img.example/isayama.jpg",
                    },
                },
                "birthday": {"year": 1986, "month": 8, "day": 29},
                "birthplace": "Oita, Japan",
                "status": "N/A",
                "stats": {"total_series": 13},
                "comments": "[Creator](https://example.com) biography.",
            },
            {
                "series_list": [
                    {
                        "series_id": 23393951235,
                        "title": "Shingeki no Kyojin",
                        "url": "https://www.mangaupdates.com/series/example",
                        "year": 2009,
                        "genres": ["Action"],
                    },
                ],
            },
        ]

        result = mangaupdates.person_page("56479861123")

        self.assertEqual(result["name"], "ISAYAMA Hajime")
        self.assertEqual(result["biography"], "Creator biography.")
        self.assertEqual(result["birth_date"], "1986-08-29")
        self.assertIsNone(result["death_date"])
        self.assertEqual(result["credits"][0]["source"], "mangaupdates")
        self.assertEqual(result["credits"][0]["media_id"], "23393951235")


class MALMangaMatchingTests(TestCase):
    def setUp(self):
        cache.clear()

    @patch("app.providers.mal.services.api_request")
    def test_match_requires_one_exact_title_without_known_conflicts(
        self,
        request_mock,
    ):
        request_mock.return_value = {
            "data": [
                {
                    "node": {
                        "id": 23390,
                        "title": "Shingeki no Kyojin",
                        "alternative_titles": {"en": "Attack on Titan"},
                        "media_type": "manga",
                        "start_date": "2009-09-09",
                    },
                },
            ],
        }
        metadata = {
            "title": "Attack on Titan",
            "details": {
                "alternative_titles": ["Shingeki no Kyojin"],
                "year": "2009",
                "format": "Manga",
            },
        }

        self.assertEqual(mal.match_manga("mu-1", metadata), "23390")
        self.assertEqual(mal.cached_manga_match("mu-1"), "23390")

    @patch("app.providers.mal.services.api_request")
    def test_match_rejects_ambiguous_or_conflicting_results(self, request_mock):
        request_mock.return_value = {
            "data": [
                {
                    "node": {
                        "id": 1,
                        "title": "Monster",
                        "media_type": "manga",
                        "start_date": "1994-01-01",
                    },
                },
                {
                    "node": {
                        "id": 2,
                        "title": "Monster",
                        "media_type": "manga",
                        "start_date": "1994-02-01",
                    },
                },
            ],
        }

        self.assertIsNone(
            mal.match_manga(
                "mu-2",
                {"title": "Monster", "details": {"year": "1994", "format": "Manga"}},
            ),
        )

        cache.clear()
        request_mock.return_value = {
            "data": [
                {
                    "node": {
                        "id": 3,
                        "title": "Monster",
                        "media_type": "novel",
                        "start_date": "1994-01-01",
                    },
                },
            ],
        }
        self.assertIsNone(
            mal.match_manga(
                "mu-3",
                {"title": "Monster", "details": {"year": "1994", "format": "Manga"}},
            ),
        )
