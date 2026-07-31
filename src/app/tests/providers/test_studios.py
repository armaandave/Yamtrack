from unittest.mock import Mock, patch

import requests
from django.core.cache import cache
from django.test import TestCase

from app.models import Sources
from app.providers import anilist, mal, services


class MALStudioProviderTests(TestCase):
    STUDIO_HTML = """
        <html>
          <head>
            <meta property="og:url"
                  content="https://myanimelist.net/anime/producer/4/Bones">
            <meta property="og:title" content="bones - Companies - MyAnimeList.net">
          </head>
          <body>
            <div class="content-left">
              <div class="logo">
                <img alt="bones" data-src="https://cdn.example.com/bones-logo.png">
              </div>
              <div class="spaceit_pad">
                Bones creates award-winning animation for television and film.
              </div>
              <div class="spaceit_pad">
                <span class="dark_text">Established:</span> October 1998
              </div>
              <div class="user-profile-sns">
                <a href="https://www.bones.co.jp/">Official Site</a>
              </div>
            </div>
            <div class="js-anime-category-studio js-anime-type-all js-anime-type-1"
                 data-genre="1">
              <div class="title"><a href="https://myanimelist.net/anime/10/Alpha">Alpha</a></div>
              <div class="image"><img data-src="https://cdn.myanimelist.net/images/anime/1/10.jpg"></div>
              <span class="js-start_date">20010101</span>
              <span class="js-score">7.5</span>
              <span class="js-members">1,000</span>
            </div>
            <div class="js-anime-category-studio js-anime-type-all js-anime-type-3"
                 data-genre="1">
              <div class="title"><a href="https://myanimelist.net/anime/20/Beta">Beta</a></div>
              <div class="image"><img src="https://cdn.myanimelist.net/images/anime/2/20.webp"></div>
              <span class="js-start_date">20020101</span>
              <span class="js-score">8.5</span>
              <span class="js-members">3,000</span>
            </div>
            <div class="js-anime-category-studio js-anime-type-all js-anime-type-5"
                 data-genre="1">
              <div class="title"><a href="https://myanimelist.net/anime/30/Gamma">Gamma</a></div>
              <div class="image"><img src="https://cdn.myanimelist.net/images/anime/3/30.jpg"></div>
              <span class="js-start_date">20030101</span>
              <span class="js-score">8.0</span>
              <span class="js-members">2,000</span>
            </div>
            <div class="js-anime-category-producer js-anime-type-1">
              <div class="title"><a href="https://myanimelist.net/anime/99/Decoy">Decoy</a></div>
              <span class="js-members">9,999</span>
            </div>
          </body>
        </html>
    """

    def setUp(self):
        cache.clear()

    def cache_identity(self, studio_id="1", name="Wit Studio", seed_id="16498"):
        mal._cache_studio_identities(  # noqa: SLF001
            [
                {
                    "id": studio_id,
                    "source": Sources.MAL.value,
                    "name": name,
                    "roles": ["Studio"],
                },
            ],
            seed_id,
        )

    def mal_page_response(self):
        response = Mock(
            text=self.STUDIO_HTML,
            url="https://myanimelist.net/anime/producer/4/Bones",
        )
        response.raise_for_status.return_value = None
        return response

    def test_mal_page_parser_extracts_rich_profile_and_exact_studio_cards(self):
        data = mal._parse_mal_studio_page(  # noqa: SLF001
            self.STUDIO_HTML,
            4,
            identity={"name": "Bones"},
        )

        self.assertEqual(
            data["profile"],
            {
                "id": "4",
                "source": Sources.MAL.value,
                "name": "Bones",
                "description": (
                    "Bones creates award-winning animation for television and film."
                ),
                "image": "https://cdn.example.com/bones-logo.png",
                "founded_year": 1998,
                "provider_url": (
                    "https://myanimelist.net/anime/producer/4/Bones"
                ),
                "websites": ["https://www.bones.co.jp/"],
            },
        )
        self.assertEqual(
            [item["media_id"] for item in data["anime"]],
            ["10", "20", "30"],
        )
        self.assertEqual(
            data["anime"][0]["image"],
            "https://cdn.myanimelist.net/images/anime/1/10l.jpg",
        )

    @patch(
        "app.providers.mal.services.api_request",
        side_effect=requests.Timeout("Jikan offline"),
    )
    def test_studio_profile_uses_public_mal_page_when_jikan_is_offline(
        self,
        request_mock,
    ):
        self.cache_identity(studio_id="4", name="Bones", seed_id="5114")

        with patch(
            "app.providers.mal.services.session.get",
            return_value=self.mal_page_response(),
        ) as mal_page_mock:
            result = mal.studio("4")

        self.assertEqual(result["name"], "Bones")
        self.assertEqual(result["image"], "https://cdn.example.com/bones-logo.png")
        self.assertEqual(result["founded_year"], 1998)
        self.assertEqual(result["websites"], ["https://www.bones.co.jp/"])
        request_mock.assert_called_once()
        mal_page_mock.assert_called_once()

    @patch(
        "app.providers.mal._jikan_studio_anime_page",
        side_effect=requests.Timeout("Jikan offline"),
    )
    def test_studio_catalog_uses_sorted_paginated_mal_page_fallback(
        self,
        jikan_mock,
    ):
        self.cache_identity(studio_id="4", name="Bones", seed_id="5114")

        with (
            patch(
                "app.providers.mal.services.session.get",
                return_value=self.mal_page_response(),
            ) as mal_page_mock,
            patch(
                "app.providers.mal._jikan_anime_genres",
                return_value=[{"id": 1, "name": "Action"}],
            ),
        ):
            result = mal.studio_anime(
                "4",
                page=2,
                page_size=1,
                sort="popularity",
                direction="desc",
            )

        self.assertEqual(result["provider"], "mal_page")
        self.assertEqual(result["previous_page"], 1)
        self.assertEqual(result["next_page"], 3)
        self.assertEqual(
            [item["media_id"] for item in result["results"]],
            ["30"],
        )
        jikan_mock.assert_called_once()
        mal_page_mock.assert_called_once()

    def test_completion_catalog_returns_and_caches_all_studio_anime(self):
        self.cache_identity(studio_id="4", name="Bones", seed_id="5114")

        with (
            patch(
                "app.providers.mal.services.session.get",
                return_value=self.mal_page_response(),
            ) as mal_page_mock,
            patch(
                "app.providers.mal._jikan_anime_genres",
                return_value=[{"id": 1, "name": "Action"}],
            ),
        ):
            first = mal.studio_anime_completion_catalog(
                "4",
                filters={"genres": ["Action"]},
            )
            second = mal.studio_anime_completion_catalog(
                "4",
                filters={"genres": ["Action"]},
            )

        self.assertTrue(first["complete"])
        self.assertEqual(first, second)
        self.assertEqual(
            [item["media_id"] for item in first["results"]],
            ["10", "20", "30"],
        )
        mal_page_mock.assert_called_once()

    @patch(
        "app.providers.mal._jikan_anime_genres",
        return_value=[{"id": 1, "name": "Action"}],
    )
    def test_completion_catalog_rejects_paginated_mal_page(
        self,
        _genres_mock,
    ):
        data = mal._parse_mal_studio_page(  # noqa: SLF001
            self.STUDIO_HTML.replace(
                "</body>",
                '<div class="pagination"><a rel="next" href="?page=2">Next</a></div></body>',
            ),
            4,
            identity={"name": "Bones"},
        )

        with patch(
            "app.providers.mal._mal_studio_page_data",
            return_value=data,
        ):
            result = mal.studio_anime_completion_catalog("4")

        self.assertFalse(result["complete"])
        self.assertEqual(result["results"], [])

    @patch(
        "app.providers.mal._jikan_anime_genres",
        return_value=[{"id": 1, "name": "Action"}],
    )
    def test_studio_filter_options_calls_real_provider_function(
        self,
        _genres_mock,
    ):
        cache.set(
            f"{mal._studio_cache_prefix(4, 'profile')}:fresh",  # noqa: SLF001
            {"founded_year": 1998},
            mal.STUDIO_FRESH_TTL,
        )

        result = mal.studio_anime_filter_options("4")

        self.assertEqual(
            result["genres"],
            [{"value": "Action", "label": "Action"}],
        )
        self.assertEqual(result["platforms"], [])
        self.assertEqual(result["years"][-1], 1998)

    @patch("app.providers.mal.services.api_request")
    def test_studio_profile_uses_jikan_and_official_cached_name(self, request_mock):
        self.cache_identity()
        request_mock.return_value = {
            "data": {
                "mal_id": 1,
                "titles": [{"type": "Default", "title": "WIT STUDIO"}],
                "images": {
                    "jpg": {
                        "image_url": "https://example.com/wit.jpg",
                    },
                },
                "about": "<b>Japanese</b> animation studio.",
                "established": "2012-06-01T00:00:00+00:00",
                "url": "https://myanimelist.net/anime/producer/1/Wit_Studio",
                "external": [
                    {
                        "name": "Official Site",
                        "url": "https://www.witstudio.co.jp/",
                    },
                ],
            },
        }

        first = mal.studio("1")
        second = mal.studio("1")

        self.assertEqual(first, second)
        self.assertEqual(first["name"], "Wit Studio")
        self.assertEqual(first["description"], "Japanese animation studio.")
        self.assertEqual(first["image"], "https://example.com/wit.jpg")
        self.assertEqual(first["founded_year"], 2012)
        self.assertEqual(first["websites"], ["https://www.witstudio.co.jp/"])
        request_mock.assert_called_once()

    @patch(
        "app.providers.mal._mal_studio_page_data",
        side_effect=requests.Timeout("MAL page offline"),
    )
    @patch(
        "app.providers.mal.services.api_request",
        side_effect=requests.Timeout("Jikan offline"),
    )
    def test_studio_profile_falls_back_to_cached_mal_identity(
        self,
        request_mock,
        mal_page_mock,
    ):
        self.cache_identity()

        result = mal.studio("1")
        cached_failure_result = mal.studio("1")

        self.assertEqual(result, cached_failure_result)
        self.assertEqual(result["name"], "Wit Studio")
        self.assertIsNone(result["description"])
        self.assertEqual(
            result["provider_url"],
            "https://myanimelist.net/anime/producer/1",
        )
        request_mock.assert_called_once()
        mal_page_mock.assert_called_once()

    @patch(
        "app.providers.mal._mal_studio_page_data",
        side_effect=requests.Timeout("MAL page offline"),
    )
    @patch(
        "app.providers.mal.services.api_request",
        return_value={"data": {}},
    )
    def test_empty_jikan_profile_sets_failure_marker_before_minimal_fallback(
        self,
        request_mock,
        mal_page_mock,
    ):
        self.cache_identity()

        first = mal.studio("1")
        second = mal.studio("1")

        self.assertEqual(first, second)
        self.assertEqual(first["name"], "Wit Studio")
        request_mock.assert_called_once()
        mal_page_mock.assert_called_once()
        self.assertTrue(
            cache.get(
                f"{mal._studio_cache_prefix(1, 'profile')}:failure",  # noqa: SLF001
            ),
        )

    @patch("app.providers.mal._jikan_anime_genres", return_value=[])
    @patch("app.providers.mal.services.api_request")
    def test_studio_catalog_keeps_only_exact_studio_credits(
        self,
        request_mock,
        _genres_mock,
    ):
        request_mock.return_value = {
            "pagination": {
                "current_page": 1,
                "has_next_page": False,
            },
            "data": [
                self.jikan_anime(
                    10,
                    "Primary",
                    studios=[{"mal_id": 1, "name": "Wit Studio"}],
                ),
                self.jikan_anime(
                    11,
                    "Producer only",
                    studios=[{"mal_id": 2, "name": "Other Studio"}],
                ),
                self.jikan_anime(
                    12,
                    "Co-production",
                    studios=[
                        {"mal_id": 1, "name": "Wit Studio"},
                        {"mal_id": 2, "name": "Other Studio"},
                    ],
                ),
            ],
        }

        first = mal.studio_anime("1")
        second = mal.studio_anime("1")

        self.assertEqual(first, second)
        self.assertIsNone(first["count"])
        self.assertEqual(
            [item["title"] for item in first["results"]],
            ["Primary", "Co-production"],
        )
        self.assertEqual(first["role_filtered"], 1)
        request_mock.assert_called_once()

    @patch("app.providers.mal._jikan_anime_genres", return_value=[])
    @patch("app.providers.mal.services.api_request")
    def test_studio_catalog_skips_empty_filtered_upstream_pages(
        self,
        request_mock,
        _genres_mock,
    ):
        request_mock.side_effect = [
            {
                "pagination": {
                    "current_page": 1,
                    "has_next_page": True,
                },
                "data": [
                    self.jikan_anime(
                        11,
                        "Producer only",
                        studios=[{"mal_id": 2, "name": "Other Studio"}],
                    ),
                ],
            },
            {
                "pagination": {
                    "current_page": 2,
                    "has_next_page": True,
                },
                "data": [
                    self.jikan_anime(
                        12,
                        "Later studio credit",
                        studios=[{"mal_id": 1, "name": "Wit Studio"}],
                    ),
                ],
            },
        ]

        result = mal.studio_anime("1")

        self.assertEqual(result["page"], 2)
        self.assertIsNone(result["previous_page"])
        self.assertEqual(result["next_page"], 3)
        self.assertEqual(result["results"][0]["title"], "Later studio credit")
        self.assertEqual(
            [call.kwargs["params"]["page"] for call in request_mock.call_args_list],
            [1, 2],
        )

    @patch(
        "app.providers.mal._jikan_anime_genres",
        return_value=[{"id": 1, "name": "Action"}],
    )
    @patch("app.providers.mal.services.api_request")
    def test_studio_catalog_maps_sort_and_filters_to_jikan(
        self,
        request_mock,
        _genres_mock,
    ):
        matching = self.jikan_anime(
            10,
            "Matching",
            studios=[{"mal_id": 1, "name": "Wit Studio"}],
        )
        below_rating = self.jikan_anime(
            11,
            "Below rating",
            studios=[{"mal_id": 1, "name": "Wit Studio"}],
        )
        below_rating["score"] = 7.5
        request_mock.return_value = {
            "pagination": {
                "current_page": 1,
                "has_next_page": False,
            },
            "data": [matching, below_rating],
        }

        result = mal.studio_anime(
            "1",
            sort="average_rating",
            direction="asc",
            filters={
                "year": 2020,
                "release_status": "released",
                "rating_min": 8,
                "rating_max": 9,
                "genres": ["Action"],
                "excluded_genres": ["Comedy"],
            },
        )

        self.assertEqual(
            [item["title"] for item in result["results"]],
            ["Matching"],
        )
        params = request_mock.call_args.kwargs["params"]
        self.assertEqual(params["order_by"], "score")
        self.assertEqual(params["sort"], "asc")
        self.assertEqual(params["genres"], "1")
        self.assertEqual(params["min_score"], 8)
        self.assertEqual(params["max_score"], 9)
        self.assertEqual(params["start_date"], "2020-01-01")
        self.assertEqual(params["end_date"], "2020-12-31")

    @patch("app.providers.mal.anime")
    @patch("app.providers.anilist.studio_anime_ids")
    @patch(
        "app.providers.mal._mal_studio_page_anime_page",
        side_effect=requests.Timeout("MAL page offline"),
    )
    @patch(
        "app.providers.mal._jikan_studio_anime_page",
        side_effect=requests.Timeout("offline"),
    )
    def test_anilist_fallback_revalidates_every_result_against_mal(
        self,
        _jikan_mock,
        _mal_page_mock,
        anilist_mock,
        anime_mock,
    ):
        self.cache_identity()
        anilist_mock.return_value = {
            "anime_ids": ["10", "11"],
            "page": 1,
            "has_next_page": False,
        }

        def anime_metadata(anime_id, **_kwargs):
            studio_id = "1" if str(anime_id) == "10" else "2"
            return {
                "media_id": str(anime_id),
                "source": Sources.MAL.value,
                "media_type": "anime",
                "title": f"Anime {anime_id}",
                "image": f"https://example.com/{anime_id}.jpg",
                "genres": ["Action"],
                "score": 8.5,
                "details": {
                    "start_date": "2020-01-01",
                    "company_credits": [
                        {
                            "id": studio_id,
                            "source": Sources.MAL.value,
                            "name": "Wit Studio",
                            "roles": ["Studio"],
                        },
                    ],
                },
            }

        anime_mock.side_effect = anime_metadata

        result = mal.studio_anime("1")

        self.assertEqual(result["provider"], "anilist")
        self.assertEqual(
            [item["media_id"] for item in result["results"]],
            ["10"],
        )
        self.assertEqual(result["role_filtered"], 1)

    @patch(
        "app.providers.mal.anime",
        side_effect=requests.Timeout("MAL offline"),
    )
    @patch("app.providers.anilist.studio_anime_ids")
    @patch(
        "app.providers.mal._mal_studio_page_anime_page",
        side_effect=requests.Timeout("MAL page offline"),
    )
    @patch(
        "app.providers.mal._jikan_studio_anime_page",
        side_effect=requests.Timeout("Jikan offline"),
    )
    def test_anilist_fallback_rejects_incomplete_mal_metadata(
        self,
        _jikan_mock,
        _mal_page_mock,
        anilist_mock,
        anime_mock,
    ):
        self.cache_identity()
        anilist_mock.return_value = {
            "anime_ids": ["10"],
            "page": 1,
            "has_next_page": False,
        }

        with self.assertRaises(services.ProviderAPIError):
            mal.studio_anime("1")

        anilist_mock.assert_called_once()
        anime_mock.assert_called_once()

    @patch(
        "app.providers.anilist.studio_anime_ids",
        side_effect=requests.Timeout("anilist offline"),
    )
    @patch(
        "app.providers.mal._mal_studio_page_anime_page",
        side_effect=requests.Timeout("MAL page offline"),
    )
    @patch(
        "app.providers.mal._jikan_studio_anime_page",
        side_effect=requests.Timeout("jikan offline"),
    )
    def test_studio_catalog_failure_marker_prevents_provider_hammering(
        self,
        jikan_mock,
        mal_page_mock,
        anilist_mock,
    ):
        self.cache_identity()

        with self.assertRaises(services.ProviderAPIError):
            mal.studio_anime("1")
        with self.assertRaises(services.ProviderAPIError):
            mal.studio_anime("1")

        jikan_mock.assert_called_once()
        mal_page_mock.assert_called_once()
        anilist_mock.assert_called_once()

    def test_studio_catalog_uses_stale_before_anilist_and_marks_failure(self):
        token = mal._studio_catalog_token(  # noqa: SLF001
            page=1,
            page_size=25,
            sort="popularity",
            direction="desc",
            filters={},
        )
        prefix = mal._studio_cache_prefix(1, f"anime:{token}")  # noqa: SLF001
        stale = {
            "count": None,
            "page": 1,
            "previous_page": None,
            "next_page": None,
            "results": [],
            "provider": "jikan",
            "role_filtered": 0,
        }
        cache.set(f"{prefix}:stale", stale, mal.STUDIO_STALE_TTL)

        with (
            patch(
                "app.providers.mal._jikan_studio_anime_page",
                side_effect=requests.Timeout("offline"),
            ) as jikan_mock,
            patch(
                "app.providers.mal._mal_studio_page_anime_page",
                side_effect=requests.Timeout("MAL page offline"),
            ) as mal_page_mock,
            patch("app.providers.anilist.studio_anime_ids") as anilist_mock,
        ):
            first = mal.studio_anime("1")
            second = mal.studio_anime("1")

        self.assertEqual(first, stale)
        self.assertEqual(second, stale)
        jikan_mock.assert_called_once()
        mal_page_mock.assert_called_once()
        anilist_mock.assert_not_called()
        self.assertTrue(cache.get(f"{prefix}:failure"))

    @patch(
        "app.providers.mal._anilist_studio_anime_page",
        side_effect=ValueError("fallback unavailable"),
    )
    @patch(
        "app.providers.mal._mal_studio_page_anime_page",
        side_effect=ValueError("MAL page unavailable"),
    )
    @patch("app.providers.mal._jikan_anime_genres", return_value=[])
    @patch("app.providers.mal.services.api_request")
    def test_jikan_sparse_page_scan_has_deterministic_ceiling(
        self,
        request_mock,
        _genres_mock,
        mal_page_mock,
        fallback_mock,
    ):
        def empty_page(*_args, **kwargs):
            page = kwargs["params"]["page"]
            return {
                "pagination": {
                    "current_page": page,
                    "has_next_page": True,
                },
                "data": [
                    self.jikan_anime(
                        page,
                        f"Producer only {page}",
                        studios=[{"mal_id": 2, "name": "Other Studio"}],
                    ),
                ],
            }

        request_mock.side_effect = empty_page

        with self.assertRaises(services.ProviderAPIError):
            mal.studio_anime("1")

        self.assertEqual(
            request_mock.call_count,
            mal.STUDIO_CATALOG_SCAN_LIMIT,
        )
        mal_page_mock.assert_called_once()
        fallback_mock.assert_called_once()

    @patch("app.providers.anilist.studio_anime_ids")
    def test_anilist_sparse_page_scan_has_deterministic_ceiling(
        self,
        anilist_mock,
    ):
        self.cache_identity()
        anilist_mock.return_value = {
            "anime_ids": [],
            "page": 1,
            "has_next_page": True,
        }

        with self.assertRaisesRegex(ValueError, "scan limit"):
            mal._anilist_studio_anime_page(  # noqa: SLF001
                1,
                page=1,
                page_size=25,
                sort="popularity",
                direction="desc",
                filters={},
            )

        self.assertEqual(
            anilist_mock.call_count,
            mal.STUDIO_CATALOG_SCAN_LIMIT,
        )

    def test_catalog_cache_token_distinguishes_zero_maximum(self):
        kwargs = {
            "page": 1,
            "page_size": 25,
            "sort": "popularity",
            "direction": "desc",
        }

        without_maximum = mal._studio_catalog_token(  # noqa: SLF001
            **kwargs,
            filters={},
        )
        zero_maximum = mal._studio_catalog_token(  # noqa: SLF001
            **kwargs,
            filters={"rating_max": 0},
        )

        self.assertNotEqual(without_maximum, zero_maximum)

    @staticmethod
    def jikan_anime(anime_id, title, *, studios):
        return {
            "mal_id": anime_id,
            "url": f"https://myanimelist.net/anime/{anime_id}",
            "title": title,
            "title_english": f"{title} English",
            "images": {
                "jpg": {
                    "large_image_url": f"https://example.com/{anime_id}.jpg",
                },
            },
            "aired": {"from": "2020-01-01T00:00:00+00:00"},
            "type": "TV",
            "episodes": 12,
            "synopsis": "Synopsis",
            "genres": [{"mal_id": 1, "name": "Action"}],
            "score": 8.0,
            "scored_by": 100,
            "members": 1_000,
            "studios": studios,
        }


class AniListStudioProviderTests(TestCase):
    @patch("app.providers.anilist.services.api_request")
    def test_studio_mapping_requires_matching_name_and_seed_credit(
        self,
        request_mock,
    ):
        request_mock.return_value = {
            "data": {
                "studio": {
                    "id": 1,
                    "name": "WIT STUDIO",
                    "isAnimationStudio": True,
                    "media": {
                        "pageInfo": {
                            "currentPage": 1,
                            "hasNextPage": False,
                        },
                        "nodes": [
                            {"idMal": 16498},
                            {"idMal": None},
                        ],
                    },
                },
                "seed": {
                    "studios": {
                        "nodes": [{"id": 1, "name": "Wit Studio"}],
                    },
                },
            },
        }

        result = anilist.studio_anime_ids(
            "1",
            studio_name="Wit Studio",
            seed_anime_id="16498",
            page=1,
            page_size=25,
            sort="popularity",
            direction="desc",
        )

        self.assertEqual(result["anime_ids"], ["16498"])
        variables = request_mock.call_args.kwargs["params"]["variables"]
        self.assertEqual(variables["sort"], ["POPULARITY_DESC"])

        request_mock.return_value["data"]["seed"]["studios"]["nodes"] = [
            {"id": 2, "name": "Other Studio"},
        ]
        with self.assertRaisesRegex(ValueError, "seed anime"):
            anilist.studio_anime_ids(
                "1",
                studio_name="Wit Studio",
                seed_anime_id="16498",
                page=1,
                page_size=25,
                sort="popularity",
                direction="desc",
            )


class StudioProviderDispatchTests(TestCase):
    @patch("app.providers.services.mal.studio")
    def test_dispatches_mal_studio_profile_and_catalogs(self, studio_mock):
        studio_mock.return_value = {"id": "1"}

        self.assertEqual(
            services.get_company(Sources.MAL.value, "1"),
            {"id": "1"},
        )
        studio_mock.assert_called_once_with("1")

        with (
            patch(
                "app.providers.services.mal.studio_anime",
                return_value={"results": []},
            ) as anime_mock,
            patch(
                "app.providers.services.mal.studio_anime_filter_options",
                return_value={"genres": []},
            ) as options_mock,
        ):
            page = services.get_company_anime(
                Sources.MAL.value,
                "1",
                page=1,
                page_size=25,
                sort="popularity",
                direction=None,
                filters={},
            )
            options = services.get_company_anime_filter_options(
                Sources.MAL.value,
                "1",
            )

        self.assertEqual(page, {"results": []})
        self.assertEqual(options, {"genres": []})
        anime_mock.assert_called_once_with(
            "1",
            page=1,
            page_size=25,
            sort="popularity",
            direction=None,
            filters={},
        )
        options_mock.assert_called_once_with("1")
