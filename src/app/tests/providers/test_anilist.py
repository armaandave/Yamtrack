from unittest.mock import patch

import requests
from django.conf import settings
from django.core.cache import cache
from django.test import TestCase

from app.models import MediaTypes, Sources
from app.providers import anilist, mal, mangaupdates, services


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
                    "reviews": {"nodes": [{"id": 1}]},
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
        self.assertEqual(
            result["rating_summary"]["score_distribution"],
            [{"score": 80, "count": 120}, {"score": 90, "count": 80}],
        )
        self.assertTrue(result["rating_summary"]["has_reviews"])
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

    def test_rating_distribution_sorts_merges_and_rejects_invalid_buckets(self):
        result = anilist._normalize_score_distribution(
            [
                {"score": 90, "amount": 2},
                {"score": 10, "amount": 3},
                {"score": 90, "amount": 4},
                {"score": 0, "amount": 1},
                {"score": 100, "amount": -1},
                {"score": "bad", "amount": 2},
                None,
            ],
        )

        self.assertEqual(
            result,
            [{"score": 10, "count": 3}, {"score": 90, "count": 6}],
        )

    @patch("app.providers.anilist.services.api_request")
    def test_reviews_normalize_filter_dedupe_and_paginate(self, request_mock):
        request_mock.return_value = {
            "data": {
                "Media": {
                    "reviews": {
                        "pageInfo": {"currentPage": 2, "hasNextPage": True},
                        "nodes": [
                            {
                                "id": 12,
                                "score": 90,
                                "summary": "<b>Excellent</b>",
                                "body": "<p>[Safe heading]() <i>review</i> body.</p>",
                                "rating": 42,
                                "ratingAmount": 50,
                                "private": False,
                                "siteUrl": "https://anilist.co/review/12",
                                "createdAt": 1_700_000_000,
                                "user": {
                                    "id": 7,
                                    "name": "reviewer",
                                    "siteUrl": "https://anilist.co/user/reviewer",
                                    "avatar": {"large": "https://img.example/user.jpg"},
                                },
                            },
                            {
                                "id": 12,
                                "body": "duplicate",
                                "user": {"id": 7, "name": "reviewer"},
                            },
                            {
                                "id": 13,
                                "private": True,
                                "body": "private",
                                "user": {"id": 8, "name": "private"},
                            },
                            {
                                "id": 14,
                                "body": "",
                                "user": {"id": 9, "name": "malformed"},
                            },
                        ],
                    },
                },
            },
        }

        result = anilist.anime_reviews("16498", 2)

        self.assertEqual(result["current_page"], 2)
        self.assertEqual(result["next_page"], 3)
        self.assertEqual([review["id"] for review in result["results"]], ["12"])
        self.assertEqual(result["results"][0]["summary"], "Excellent")
        self.assertEqual(
            result["results"][0]["body"],
            "Safe heading review body.",
        )
        self.assertEqual(result["results"][0]["score"], 90)
        self.assertEqual(result["results"][0]["community_rating_count"], 50)
        self.assertEqual(
            request_mock.call_args.kwargs["params"]["variables"],
            {"malId": 16498, "page": 2},
        )
        self.assertIn(
            "sort: [RATING_DESC, ID_DESC]",
            request_mock.call_args.kwargs["params"]["query"],
        )

    @patch("app.providers.anilist.services.api_request")
    def test_reviews_use_stale_page_and_failure_marker(self, request_mock):
        stale = {"current_page": 1, "next_page": None, "results": []}
        cache.set(
            f"anilist:{anilist.REVIEWS_CACHE_VERSION}:anime:1:reviews:1:stale",
            stale,
            anilist.REVIEWS_STALE_TTL,
        )
        request_mock.side_effect = requests.Timeout("down")

        self.assertEqual(anilist.anime_reviews("1", 1), stale)
        self.assertEqual(anilist.anime_reviews("1", 1), stale)
        request_mock.assert_called_once()

    @patch("app.providers.anilist.services.api_request")
    def test_reviews_raise_provider_error_without_stale_page(self, request_mock):
        request_mock.side_effect = requests.Timeout("down")

        with self.assertRaises(anilist.services.ProviderAPIError):
            anilist.anime_reviews("1", 1)

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

    @patch("app.providers.mal.person_page_by_name", return_value=None)
    @patch("app.providers.anilist.services.api_request")
    def test_person_page_normalizes_profile_and_mal_manga_credits(
        self,
        request_mock,
        _mal_person_mock,
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

    def test_staff_biography_removes_markup_links_and_collapsed_role_dumps(self):
        biography = anilist._staff_biography(
            """
            <p><strong>Height:</strong> 161 cm</p>
            <p><a href="https://example.com/twitter">Twitter</a> |
            <a href="https://example.com/blog">Blog</a></p>
            <p>She is an award-winning voice actor.</p>
            <p><strong>Non-Anime Roles:</strong><br>
            <span class="markdown_spoiler"><span>- A role</p>
            <ul><li>Another role</li>
            <li>Final role<br></span></span></li></ul>
            """,
        )

        self.assertEqual(
            biography,
            "Height: 161 cm\n\nShe is an award-winning voice actor.",
        )

    def test_staff_query_requests_ranked_credits_and_rendered_biography(self):
        self.assertIn("description(asHtml: true)", anilist.STAFF_QUERY)
        self.assertEqual(
            anilist.STAFF_QUERY.count("sort: [POPULARITY_DESC, SCORE_DESC]"),
            3,
        )
        self.assertEqual(anilist.STAFF_QUERY.count("perPage: 25"), 3)
        self.assertIn("characterRole", anilist.STAFF_QUERY)

    @patch("app.providers.anilist._schedule_person_page_refresh")
    @patch("app.providers.anilist.services.api_request")
    def test_person_page_returns_stale_immediately_and_schedules_refresh(
        self,
        request_mock,
        schedule_mock,
    ):
        _, stale_key, _, _ = anilist._person_page_keys("100142", 1)
        cache.set(
            stale_key,
            {
                "staff": {
                    "id": 100142,
                    "name": {"full": "Yui Ishikawa"},
                    "primaryOccupations": ["Voice Actor"],
                },
                "manga_edges": [],
                "anime_staff_edges": [],
                "anime_voice_edges": [],
                "has_next_page": False,
            },
            60,
        )

        result = anilist.person_page("100142")

        self.assertEqual(result["name"], "Yui Ishikawa")
        request_mock.assert_not_called()
        schedule_mock.assert_called_once_with("100142", 1)

    @patch(
        "app.providers.mal.person_page_by_name",
        return_value={
            "credits": [
                {
                    "media_type": MediaTypes.ANIME.value,
                    "media_id": "16498",
                    "image": "https://cdn.myanimelist.net/aot.jpg",
                },
                {
                    "media_type": MediaTypes.ANIME.value,
                    "media_id": "49596",
                    "image": "https://cdn.myanimelist.net/blue-lock.jpg",
                },
            ],
        },
    )
    @patch("app.providers.anilist.services.api_request")
    def test_person_page_paginates_and_merges_anime_voice_and_staff_credits(
        self,
        request_mock,
        mal_person_mock,
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
                    {
                        "characterRole": "MAIN",
                        "characters": [{"id": 1}],
                        "node": attack_on_titan,
                    },
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

        first_page = anilist.person_page("110665")
        self.assertEqual(request_mock.call_count, 1)
        self.assertIs(
            request_mock.call_args.kwargs["request_session"],
            requests,
        )
        result = anilist.person_page("110665", page=2)

        self.assertEqual(request_mock.call_count, 2)
        self.assertEqual(first_page["credits_page"], 1)
        self.assertEqual(first_page["credits_next_page"], 2)
        self.assertEqual(result["credits_page"], 2)
        self.assertIsNone(result["credits_next_page"])
        self.assertEqual(result["alternative_names"], ["梶裕貴", "Kaji Yuki"])
        self.assertEqual(result["known_for_department"], "Voice Actor")
        self.assertEqual(len(result["credits"]), 2)
        attack_credit = result["credits"][0]
        self.assertEqual(attack_credit["media_type"], "anime")
        self.assertEqual(attack_credit["source"], "mal")
        self.assertEqual(attack_credit["media_id"], "16498")
        self.assertEqual(
            attack_credit["image"],
            "https://cdn.myanimelist.net/aot.jpg",
        )
        self.assertEqual(
            attack_credit["credit_roles"],
            ["Theme Song Performance", "Key Animation", "Voice Actor"],
        )
        self.assertEqual(attack_credit["character_role"], "MAIN")
        self.assertEqual(result["credits"][1]["media_id"], "49596")
        self.assertEqual(
            result["credits"][1]["image"],
            "https://cdn.myanimelist.net/blue-lock.jpg",
        )
        self.assertEqual(result["credits"][1]["credit_roles"], ["Voice Actor"])
        mal_person_mock.assert_called_once_with(
            "Yuki Kaji",
            ["梶裕貴", "Kaji Yuki"],
            "1985-09-03",
            timeout=1,
            request_session=requests,
        )

    @patch("app.providers.mal.cached_anime_posters", return_value={})
    @patch("app.providers.anilist.refresh_person_credit_images", return_value={})
    def test_person_page_keeps_anilist_cover_when_mal_is_unavailable(
        self,
        _refresh_mock,
        _cached_poster_mock,
    ):
        person = {
            "credits": [{
                "media_type": MediaTypes.ANIME.value,
                "media_id": "21",
                "image": "https://img.anilist.co/one-piece.jpg",
            }],
        }

        anilist._apply_mal_anime_credit_images(
            "950",
            {"name": {"full": "Mayumi Tanaka"}},
            person,
        )

        self.assertEqual(
            person["credits"][0]["image"],
            "https://img.anilist.co/one-piece.jpg",
        )
        _cached_poster_mock.assert_called_once()

    @patch(
        "app.providers.mal.cached_anime_posters",
        return_value={"21": "https://cdn.myanimelist.net/one-piece.jpg"},
    )
    @patch("app.providers.anilist.refresh_person_credit_images", return_value={})
    def test_person_page_uses_cached_mal_poster_when_jikan_is_unavailable(
        self,
        _refresh_mock,
        _cached_poster_mock,
    ):
        person = {
            "credits": [{
                "media_type": MediaTypes.ANIME.value,
                "media_id": "21",
                "image": "https://img.anilist.co/one-piece.jpg",
            }],
        }

        anilist._apply_mal_anime_credit_images(
            "950",
            {"name": {"full": "Mayumi Tanaka"}},
            person,
        )

        self.assertEqual(
            person["credits"][0]["image"],
            "https://cdn.myanimelist.net/one-piece.jpg",
        )
        _cached_poster_mock.assert_called_once()


class MALAnimeMetadataTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_cached_anime_poster_returns_only_valid_mal_artwork(self):
        cache_key = (
            f"{Sources.MAL.value}_{MediaTypes.ANIME.value}_21_"
            f"{mal.ANIME_CACHE_VERSION}"
        )
        cache.set(cache_key, {"image": "https://cdn.myanimelist.net/one-piece.jpg"})
        mal._cache_anime_poster(
            "16498",
            "https://cdn.myanimelist.net/attack-on-titan.jpg",
        )

        self.assertEqual(
            mal.cached_anime_poster("21"),
            "https://cdn.myanimelist.net/one-piece.jpg",
        )
        self.assertEqual(
            mal.cached_anime_posters(["21", "16498", "missing"]),
            {
                "21": "https://cdn.myanimelist.net/one-piece.jpg",
                "16498": "https://cdn.myanimelist.net/attack-on-titan.jpg",
            },
        )

        cache.set(cache_key, {"image": settings.IMG_NONE})
        self.assertIsNone(mal.cached_anime_poster("21"))

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
            "num_list_users": 250,
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
            "recommendations": [
                {
                    "node": {
                        "id": 200,
                        "title": "A Recommendation",
                        "main_picture": {
                            "large": "https://img.example/recommendation.jpg",
                        },
                    },
                },
            ],
        }

        result = mal.anime("16498")

        self.assertEqual(result["title"], "Shingeki no Kyojin")
        self.assertEqual(result["display_title"], "Attack on Titan")
        self.assertEqual(result["member_count"], 250)
        self.assertEqual(len(result["posters"]), 2)
        self.assertEqual(result["details"]["studios"], ["Wit Studio"])
        self.assertEqual(
            result["details"]["company_credits"],
            [
                {
                    "id": "1",
                    "source": Sources.MAL.value,
                    "name": "Wit Studio",
                    "roles": ["Studio"],
                },
            ],
        )
        self.assertEqual(
            mal.cached_studio_identity("1"),
            {
                "id": "1",
                "name": "Wit Studio",
                "seed_anime_id": "16498",
            },
        )
        self.assertEqual(result["related"]["relations"][0]["relation"], "Prequel")
        self.assertNotIn("relation", result["related"]["recommendations"][0])
        self.assertEqual(
            mal.cached_anime_poster("16498"),
            "https://img.example/main.jpg",
        )
        self.assertEqual(
            mal.cached_anime_poster("100"),
            "https://img.example/prequel.jpg",
        )
        self.assertEqual(
            mal.cached_anime_poster("200"),
            "https://img.example/recommendation.jpg",
        )
        fields = request_mock.call_args.kwargs["params"]["fields"]
        self.assertIn("alternative_titles", fields)
        self.assertIn("num_list_users", fields)
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

    @patch("app.providers.mal.person_page")
    @patch("app.providers.mal.services.api_request")
    def test_person_page_by_name_matches_reversed_name_and_birthday(
        self,
        request_mock,
        person_mock,
    ):
        request_mock.return_value = {
            "data": [
                {
                    "mal_id": 1,
                    "name": "Ishikawa, Yui",
                    "birthday": "1988-01-01T00:00:00+00:00",
                    "favorites": 1000,
                },
                {
                    "mal_id": 2,
                    "name": "Ishikawa Yui",
                    "birthday": "1989-05-30T00:00:00+00:00",
                    "favorites": 900,
                },
            ],
        }
        person_mock.return_value = {"person_id": "2", "credits": []}

        result = mal.person_page_by_name(
            "Yui Ishikawa",
            ["石川由依"],
            "1989-05-30",
            request_session=requests,
        )

        self.assertEqual(result["person_id"], "2")
        person_mock.assert_called_once_with(
            2,
            timeout=1,
            retry_rate_limits=False,
            request_session=requests,
        )
        self.assertEqual(request_mock.call_args.kwargs["timeout"], 1)
        self.assertFalse(request_mock.call_args.kwargs["retry_rate_limits"])
        self.assertIs(request_mock.call_args.kwargs["request_session"], requests)

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


class AnimeSeriesProviderTests(TestCase):
    def setUp(self):
        cache.clear()

    @patch("app.providers.anilist.anime_series_nodes")
    @patch("app.providers.mal.anime")
    def test_resolves_linear_series_from_any_member_with_mal_direction(
        self,
        anime_mock,
        nodes_mock,
    ):
        anime_mock.side_effect = lambda media_id, **_kwargs: self._anime(
            media_id,
            {
                "1": [("2", "Sequel")],
                "2": [("1", "Prequel"), ("3", "Sequel")],
                "3": [("2", "Prequel")],
            },
        )
        nodes_mock.side_effect = lambda ids, **_kwargs: {
            str(media_id): {
                "series_links": (
                    [{"media_id": "2", "relation": "Prequel"}]
                    if str(media_id) == "1"
                    else []
                ),
            }
            for media_id in ids
        }

        result = mal.anime_series("2")

        self.assertEqual(result["series_id"], "1")
        self.assertEqual([item["media_id"] for item in result["items"]], ["1", "2", "3"])
        self.assertEqual([item["position"] for item in result["items"]], [1, 2, 3])
        self.assertEqual(mal.anime_series("3"), result)

    @patch("app.providers.anilist.anime_series_nodes", return_value={})
    @patch("app.providers.mal.anime")
    def test_orders_branches_by_date_and_retains_every_format(
        self,
        anime_mock,
        _nodes_mock,
    ):
        anime_mock.side_effect = lambda media_id, **_kwargs: self._anime(
            media_id,
            {
                "10": [("11", "Sequel"), ("12", "Sequel")],
                "11": [("10", "Prequel")],
                "12": [("10", "Prequel")],
            },
            dates={"10": "2020-01-01", "11": "2021-06-01", "12": "2021-01-01"},
            formats={"12": "OVA"},
        )

        result = mal.anime_series("11")

        self.assertEqual([item["media_id"] for item in result["items"]], ["10", "12", "11"])
        self.assertIn("OVA", result["items"][1]["subtitle"])

    @patch("app.providers.anilist.anime_series_nodes")
    @patch("app.providers.mal.anime")
    def test_names_series_after_most_popular_member_without_changing_root(
        self,
        anime_mock,
        nodes_mock,
    ):
        anime_mock.side_effect = lambda media_id, **_kwargs: self._anime(
            media_id,
            {
                "1": [("2", "Sequel")],
                "2": [("1", "Prequel")],
            },
            member_counts={"1": 100, "2": 1_000},
            titles={"1": "Prequel OVA", "2": "Public Series Name"},
        )
        nodes_mock.side_effect = lambda ids, **_kwargs: {
            str(media_id): {
                "popularity": 10_000 if str(media_id) == "1" else 1,
                "series_links": [],
            }
            for media_id in ids
        }

        result = mal.anime_series("1")

        self.assertEqual(result["series_id"], "1")
        self.assertEqual(result["representative_id"], "2")
        self.assertEqual(result["name"], "Public Series Name")

    @patch("app.providers.anilist.anime_series_nodes")
    @patch("app.providers.mal.anime")
    def test_uses_anilist_popularity_when_mal_member_counts_are_missing(
        self,
        anime_mock,
        nodes_mock,
    ):
        anime_mock.side_effect = lambda media_id, **_kwargs: self._anime(
            media_id,
            {
                "1": [("2", "Sequel")],
                "2": [("1", "Prequel")],
            },
            titles={"1": None, "2": None},
        )
        nodes_mock.side_effect = lambda ids, **_kwargs: {
            str(media_id): {
                "display_title": (
                    "AniList First"
                    if str(media_id) == "1"
                    else "AniList Popular"
                ),
                "popularity": 100 if str(media_id) == "1" else 200,
                "series_links": [],
            }
            for media_id in ids
        }

        result = mal.anime_series("1")

        self.assertEqual(result["representative_id"], "2")
        self.assertEqual(result["name"], "AniList Popular")

    def test_representative_ties_use_format_then_date_then_mal_id(self):
        candidates = [
            self._anime(
                "4",
                {},
                dates={"4": "2010-01-01"},
                formats={"4": "Movie"},
                member_counts={"4": 100},
            ),
            self._anime(
                "3",
                {},
                dates={"3": "2020-01-01"},
                formats={"3": "TV"},
                member_counts={"3": 100},
            ),
            self._anime(
                "2",
                {},
                dates={"2": "2018-01-01"},
                formats={"2": "TV"},
                member_counts={"2": 100},
            ),
            self._anime(
                "1",
                {},
                dates={"1": "2018-01-01"},
                formats={"1": "TV"},
                member_counts={"1": 100},
            ),
        ]

        representative = min(candidates, key=mal._anime_series_representative_key)

        self.assertEqual(str(representative["media_id"]), "1")

    def test_cycle_retains_members_in_deterministic_date_order(self):
        metadata = {
            "1": self._anime("1", {}, dates={"1": "2021-01-01"}),
            "2": self._anime("2", {}, dates={"2": "2020-01-01"}),
        }

        ordered, cycled = mal._ordered_anime_series_ids(
            metadata,
            [("1", "2"), ("2", "1")],
        )

        self.assertTrue(cycled)
        self.assertEqual(ordered, ["2", "1"])

    @patch("app.providers.mal._resolve_anime_series", side_effect=TimeoutError)
    def test_uses_stale_canonical_payload_when_refresh_fails(self, _resolve_mock):
        stale = {
            "series_id": "1",
            "source": "mal",
            "media_type": "anime",
            "name": "Series",
            "item_count": 2,
            "items": [{"media_id": "1"}, {"media_id": "2"}],
        }
        cache.set(mal._anime_series_key("alias", "2"), "1", 60)
        cache.set(mal._anime_series_key("stale", "1"), stale, 60)

        self.assertEqual(mal.anime_series("2"), stale)
        self.assertTrue(cache.get(mal._anime_series_key("failure", "2")))

    @patch("app.providers.anilist.anime_series_nodes", return_value={})
    @patch("app.providers.mal.anime")
    def test_single_anime_is_not_exposed_as_a_series(
        self,
        anime_mock,
        _nodes_mock,
    ):
        anime_mock.return_value = self._anime("1", {})

        for _attempt in range(2):
            with self.assertRaisesRegex(services.ProviderAPIError, "Anime series") as error:
                mal.anime_series("1")
            self.assertEqual(error.exception.status_code, requests.codes.not_found)

    @staticmethod
    def _anime(
        media_id,
        links,
        dates=None,
        formats=None,
        member_counts=None,
        titles=None,
    ):
        media_id = str(media_id)
        dates = dates or {}
        formats = formats or {}
        member_counts = member_counts or {}
        titles = titles or {}
        return {
            "media_id": media_id,
            "source": "mal",
            "media_type": "anime",
            "title": f"Anime {media_id}",
            "display_title": titles.get(media_id, f"English {media_id}"),
            "member_count": member_counts.get(media_id),
            "image": f"https://img.example/{media_id}.jpg",
            "details": {
                "format": formats.get(media_id, "Anime"),
                "start_date": dates.get(media_id, f"202{int(media_id) - 1}-01-01"),
                "episodes": 12,
            },
            "related": {
                "relations": [
                    {
                        "media_id": neighbor,
                        "source": "mal",
                        "media_type": "anime",
                        "title": f"Anime {neighbor}",
                        "relation": relation,
                    }
                    for neighbor, relation in links.get(media_id, [])
                ],
            },
        }
