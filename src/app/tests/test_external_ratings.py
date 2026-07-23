from datetime import timedelta
from decimal import Decimal
from unittest.mock import call, patch

import requests
from django.test import TestCase, override_settings
from django.utils import timezone

from app.external_ratings import (
    FRESH_FOR,
    RATING_SOURCES,
    TransientExternalRatingError,
    eligible_rating_sources,
    rating_source_is_exposed,
    rating_sources_needing_refresh,
    refresh_external_ratings,
)
from app.models import ExternalRating, Item, MediaTypes, Sources


class ExternalRatingServiceTests(TestCase):
    def setUp(self):
        self.movie = Item.objects.create(
            media_id="550",
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            title="Fight Club",
            image="https://example.com/fight-club.jpg",
        )

    def test_registry_contract(self):
        self.assertEqual(
            set(RATING_SOURCES),
            {
                "tmdb",
                "imdb",
                "letterboxd",
                "tomatoes",
                "mal",
                "mangaupdates",
                "igdb",
                "metacritic",
                "openlibrary",
                "hardcover",
                "musicbrainz",
            },
        )
        self.assertEqual(FRESH_FOR, timedelta(hours=24))
        self.assertTrue(
            all(
                definition["fresh_for"] == FRESH_FOR
                for definition in RATING_SOURCES.values()
            ),
        )
        self.assertEqual(RATING_SOURCES["tomatoes"]["max_value"], Decimal("100"))
        self.assertEqual(RATING_SOURCES["tomatoes"]["wire_max"], "100%")

    def test_refresh_selection_uses_terminal_status_and_registry_freshness(self):
        now = timezone.now()
        ExternalRating.objects.create(
            item=self.movie,
            rating_source="imdb",
            value="8.8",
            max_value=10,
            status=ExternalRating.Status.AVAILABLE,
            last_attempted_at=now,
            last_success_at=now,
        )
        ExternalRating.objects.create(
            item=self.movie,
            rating_source="letterboxd",
            max_value=5,
            status=ExternalRating.Status.UNAVAILABLE,
            last_attempted_at=now - FRESH_FOR - timedelta(seconds=1),
        )
        ExternalRating.objects.create(
            item=self.movie,
            rating_source="tomatoes",
            max_value=100,
            status=ExternalRating.Status.FAILED,
            last_attempted_at=now,
        )

        self.assertEqual(
            rating_sources_needing_refresh(self.movie, now=now),
            ["tmdb", "letterboxd", "tomatoes"],
        )
        self.assertEqual(
            rating_sources_needing_refresh(
                self.movie,
                ["imdb"],
                force=True,
                now=now,
            ),
            ["imdb"],
        )

    @patch("app.providers.mdblist.get_media_ratings")
    def test_one_mdblist_call_persists_all_grouped_sources(self, ratings_mock):
        ratings_mock.return_value = {
            "imdb": {
                "value": "8.8",
                "votes": 2300000,
                "url": "https://www.imdb.com/title/tt0137523/",
            },
            "tomatoes": {
                "value": "79%",
                "votes": 100,
                "url": "/m/fight_club",
            },
        }

        outcomes = refresh_external_ratings(self.movie, ["imdb"])

        ratings_mock.assert_called_once_with("550", MediaTypes.MOVIE.value)
        self.assertEqual(
            outcomes,
            {
                "imdb": ExternalRating.Status.AVAILABLE,
                "letterboxd": ExternalRating.Status.UNAVAILABLE,
                "tomatoes": ExternalRating.Status.AVAILABLE,
            },
        )
        ratings = {
            rating.rating_source: rating
            for rating in self.movie.external_ratings.all()
        }
        self.assertEqual(ratings["imdb"].value, Decimal("8.8"))
        self.assertEqual(ratings["imdb"].vote_count, 2300000)
        self.assertEqual(ratings["tomatoes"].value, Decimal("79"))
        self.assertEqual(ratings["tomatoes"].max_value, Decimal("100"))
        self.assertIsNone(ratings["letterboxd"].value)
        self.assertEqual(
            ratings["tomatoes"].canonical_url,
            "https://www.rottentomatoes.com/m/fight_club",
        )
        self.movie.refresh_from_db()
        self.assertEqual(self.movie.imdb_rating, Decimal("8.8"))
        self.assertIsNone(self.movie.letterboxd_rating)
        self.assertEqual(self.movie.rotten_tomatoes_rating, Decimal("79"))

    @patch("app.providers.services.get_media_metadata")
    def test_native_rating_upserts_one_row(self, metadata_mock):
        item = Item.objects.create(
            media_id="1",
            source=Sources.MAL.value,
            media_type=MediaTypes.ANIME.value,
            title="Cowboy Bebop",
            image="https://example.com/bebop.jpg",
        )
        metadata_mock.side_effect = [
            {
                "score": "8.7",
                "score_count": 100,
                "source_url": "https://myanimelist.net/anime/1",
            },
            {
                "score": "8.8",
                "score_count": 110,
                "source_url": "https://myanimelist.net/anime/1",
            },
        ]

        refresh_external_ratings(item)
        refresh_external_ratings(item)

        rating = item.external_ratings.get(rating_source="mal")
        self.assertEqual(item.external_ratings.count(), 1)
        self.assertEqual(rating.value, Decimal("8.8"))
        self.assertEqual(rating.vote_count, 110)
        self.assertEqual(rating.status, ExternalRating.Status.AVAILABLE)

    @override_settings(
        IMDB_API_KEY="key",
        IMDB_DATA_SET_ID="dataset",
        IMDB_REVISION_ID="revision",
        IMDB_ASSET_ID="asset",
    )
    @patch("app.providers.imdb.get_title_rating")
    @patch("app.providers.services.get_media_metadata")
    def test_episode_refresh_uses_exact_identity(self, metadata_mock, imdb_mock):
        episodes = [
            Item.objects.create(
                media_id="1399",
                source=Sources.TMDB.value,
                media_type=MediaTypes.EPISODE.value,
                season_number=1,
                episode_number=number,
                title=f"Episode {number}",
                image="https://example.com/episode.jpg",
            )
            for number in (1, 2)
        ]
        metadata_mock.side_effect = [
            {"imdb_id": "tt001"},
            {"imdb_id": "tt002"},
        ]
        imdb_mock.side_effect = [
            {"value": "7.5", "votes": 10},
            {"value": "9.0", "votes": 20},
        ]

        for episode in episodes:
            refresh_external_ratings(episode)

        self.assertEqual(
            metadata_mock.call_args_list,
            [
                call(
                    MediaTypes.EPISODE.value,
                    "1399",
                    Sources.TMDB.value,
                    season_numbers=[1],
                    episode_number=1,
                ),
                call(
                    MediaTypes.EPISODE.value,
                    "1399",
                    Sources.TMDB.value,
                    season_numbers=[1],
                    episode_number=2,
                ),
            ],
        )
        self.assertEqual(
            imdb_mock.call_args_list,
            [
                call("tt001", raise_errors=True),
                call("tt002", raise_errors=True),
            ],
        )
        self.assertEqual(
            episodes[0].external_ratings.get(rating_source="imdb").value,
            Decimal("7.5"),
        )
        self.assertEqual(
            episodes[1].external_ratings.get(rating_source="imdb").value,
            Decimal("9.0"),
        )

    @patch("app.providers.mdblist.get_media_ratings")
    def test_invalid_provider_value_is_recorded_as_failed(self, ratings_mock):
        ratings_mock.return_value = {"imdb": {"value": "NaN"}}

        outcomes = refresh_external_ratings(self.movie, ["imdb"])

        rating = self.movie.external_ratings.get(rating_source="imdb")
        self.assertEqual(outcomes["imdb"], ExternalRating.Status.FAILED)
        self.assertEqual(rating.status, ExternalRating.Status.FAILED)
        self.assertIsNone(rating.value)
        self.assertEqual(rating.last_error, "Invalid imdb rating value")

    @patch("app.providers.mdblist.get_media_ratings")
    def test_grouped_response_can_mix_terminal_and_failed_outcomes(self, ratings_mock):
        ratings_mock.return_value = {
            "imdb": {"value": "8.8"},
            "letterboxd": {"value": "invalid"},
        }

        outcomes = refresh_external_ratings(self.movie, ["imdb"])

        self.assertEqual(
            outcomes,
            {
                "imdb": ExternalRating.Status.AVAILABLE,
                "letterboxd": ExternalRating.Status.FAILED,
                "tomatoes": ExternalRating.Status.UNAVAILABLE,
            },
        )

    @patch("app.providers.mdblist.get_media_ratings")
    def test_transient_failures_raise_only_when_requested(self, ratings_mock):
        ratings_mock.side_effect = requests.exceptions.Timeout("timed out")

        outcomes = refresh_external_ratings(self.movie, ["imdb"])

        self.assertEqual(outcomes["imdb"], ExternalRating.Status.FAILED)
        with self.assertRaises(TransientExternalRatingError) as raised:
            refresh_external_ratings(
                self.movie,
                ["imdb"],
                raise_transient=True,
            )
        self.assertEqual(
            raised.exception.sources,
            ("imdb", "letterboxd", "tomatoes"),
        )

    @patch("app.providers.mdblist.get_media_ratings")
    def test_only_retryable_http_statuses_raise_transient(self, ratings_mock):
        not_found = requests.Response()
        not_found.status_code = 404
        ratings_mock.side_effect = requests.exceptions.HTTPError(response=not_found)

        outcomes = refresh_external_ratings(
            self.movie,
            ["imdb"],
            raise_transient=True,
        )

        self.assertEqual(outcomes["imdb"], ExternalRating.Status.FAILED)
        unavailable = requests.Response()
        unavailable.status_code = 503
        ratings_mock.side_effect = requests.exceptions.HTTPError(response=unavailable)
        with self.assertRaises(TransientExternalRatingError):
            refresh_external_ratings(
                self.movie,
                ["imdb"],
                raise_transient=True,
            )

    @patch("app.providers.mdblist.get_media_ratings")
    def test_failure_preserves_successful_values(self, ratings_mock):
        ratings_mock.return_value = {
            "letterboxd": {
                "value": "4.3",
                "votes": 500000,
                "url": "https://letterboxd.com/film/fight-club/",
            },
        }
        refresh_external_ratings(self.movie, ["letterboxd"])
        before = self.movie.external_ratings.get(rating_source="letterboxd")
        successful_at = before.last_success_at

        ratings_mock.side_effect = RuntimeError("x" * 2000)
        refresh_external_ratings(self.movie, ["letterboxd"])

        before.refresh_from_db()
        self.assertEqual(before.status, ExternalRating.Status.FAILED)
        self.assertEqual(before.value, Decimal("4.3"))
        self.assertEqual(before.max_value, Decimal("5"))
        self.assertEqual(before.vote_count, 500000)
        self.assertEqual(
            before.canonical_url,
            "https://letterboxd.com/film/fight-club/",
        )
        self.assertEqual(before.last_success_at, successful_at)
        self.assertEqual(len(before.last_error), 1000)
        self.movie.refresh_from_db()
        self.assertEqual(self.movie.letterboxd_rating, Decimal("4.3"))

    @patch("app.providers.mdblist.get_media_ratings")
    def test_unavailable_clears_legacy_value(self, ratings_mock):
        ratings_mock.return_value = {"imdb": {"value": "8.8"}}
        refresh_external_ratings(self.movie, ["imdb"])
        ratings_mock.return_value = {}

        refresh_external_ratings(self.movie, ["imdb"])

        self.movie.refresh_from_db()
        self.assertIsNone(self.movie.imdb_rating)
        rating = self.movie.external_ratings.get(rating_source="imdb")
        self.assertEqual(rating.status, ExternalRating.Status.UNAVAILABLE)
        self.assertIsNone(rating.value)

    @patch("app.providers.services.get_media_metadata")
    def test_supplied_metadata_avoids_duplicate_provider_lookup(self, metadata_mock):
        item = Item.objects.create(
            media_id="1",
            source=Sources.MAL.value,
            media_type=MediaTypes.ANIME.value,
            title="Cowboy Bebop",
            image="https://example.com/bebop.jpg",
        )

        refresh_external_ratings(
            item,
            metadata={"score": "8.7", "score_count": 100},
        )

        metadata_mock.assert_not_called()
        self.assertEqual(
            item.external_ratings.get(rating_source="mal").value,
            Decimal("8.7"),
        )

    @patch("app.providers.services.get_media_metadata")
    def test_unsupported_and_unknown_sources_do_not_fetch(self, metadata_mock):
        manual = Item.objects.create(
            media_id=Item.generate_manual_id(),
            source=Sources.MANUAL.value,
            media_type=MediaTypes.MOVIE.value,
            title="Manual Movie",
            image="https://example.com/manual.jpg",
        )

        self.assertEqual(
            refresh_external_ratings(manual, ["tmdb"]),
            {"tmdb": "skipped"},
        )
        with self.assertRaisesMessage(ValueError, "Unknown rating source: goodreads"):
            refresh_external_ratings(manual, ["goodreads"])
        metadata_mock.assert_not_called()
        self.assertFalse(manual.external_ratings.exists())

    @override_settings(MUSICBRAINZ_EXTERNAL_RATINGS_ENABLED=False)
    def test_musicbrainz_rating_gate_disables_fetch_and_exposure(self):
        item = Item.objects.create(
            media_id="release-group",
            source=Sources.MUSICBRAINZ.value,
            media_type=MediaTypes.MUSIC.value,
            title="Album",
        )

        self.assertEqual(eligible_rating_sources(item), [])
        self.assertFalse(rating_source_is_exposed("musicbrainz"))
