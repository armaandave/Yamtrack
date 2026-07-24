from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.db import connection
from django.db.backends.postgresql.base import DatabaseWrapper
from django.test import TestCase
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from api.services import filters as filter_service
from app.models import (
    DiaryEntry,
    ExternalRating,
    Game,
    Item,
    MediaTypes,
    Movie,
    Sources,
    Status,
)
from lists.models import CustomList, CustomListItem


class ExternalRatingCollectionSortTests(TestCase):
    """Contract tests for stored external-rating collection ordering."""

    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="external-rating-sorts",
            password="strong-password-123",
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.now = timezone.now()

    def _item(self, media_id, title, **kwargs):
        return Item.objects.create(
            source=kwargs.pop("source", Sources.TMDB.value),
            media_type=kwargs.pop("media_type", MediaTypes.MOVIE.value),
            media_id=media_id,
            title=title,
            **kwargs,
        )

    def _rating(self, item, source, value=None, status_value=ExternalRating.Status.AVAILABLE):
        max_values = {
            "letterboxd": Decimal(5),
            "steam": Decimal(100),
            "tomatoes": Decimal(100),
        }
        return ExternalRating.objects.create(
            item=item,
            rating_source=source,
            value=value,
            max_value=max_values.get(source, Decimal(10)),
            status=status_value,
            last_attempted_at=self.now,
            last_success_at=self.now if value is not None else None,
        )

    @staticmethod
    def _titles(response, collection):
        if collection == "tracking":
            return [result["media"]["title"] for result in response.data["results"]]
        if collection == "diary":
            return [result["media"]["title"] for result in response.data["results"]]
        return [result["title"] for result in response.data["results"]]

    @patch("app.tasks.enrich_external_ratings.delay")
    @patch("app.external_ratings.refresh_external_ratings")
    @patch("app.providers.services.get_media_metadata")
    @patch("app.providers.steam.get_metacritic_rating")
    @patch("app.providers.imdb.get_title_rating")
    @patch("app.providers.mdblist.get_media_ratings")
    def test_external_rating_orders_full_collections_before_pagination_without_fetching(
        self,
        mdblist_mock,
        imdb_mock,
        metacritic_mock,
        metadata_mock,
        refresh_mock,
        enqueue_mock,
    ):
        items = [self._item(f"paged-{index}", f"Movie {index:02d}") for index in range(30)]
        Movie.objects.bulk_create([
            Movie(user=self.user, item=item, status=Status.COMPLETED.value)
            for item in items
        ])
        DiaryEntry.objects.bulk_create([
            DiaryEntry(user=self.user, item=item, consumed_at=self.now)
            for item in items
        ])
        custom_list = CustomList.objects.create(owner=self.user, name="Paged Ratings")
        CustomListItem.objects.bulk_create([
            CustomListItem(custom_list=custom_list, item=item)
            for item in items
        ])
        ExternalRating.objects.bulk_create([
            ExternalRating(
                item=item,
                rating_source="imdb",
                value=Decimal(index) / 10,
                max_value=Decimal(10),
                status=ExternalRating.Status.AVAILABLE,
                last_attempted_at=self.now,
                last_success_at=self.now,
            )
            for index, item in enumerate(items[:26])
        ])
        self._rating(items[27], "imdb", status_value=ExternalRating.Status.UNAVAILABLE)
        self._rating(items[28], "imdb", Decimal("9.8"), ExternalRating.Status.FAILED)
        self._rating(items[29], "imdb", Decimal("9.9"))

        endpoints = {
            "tracking": "/api/v1/tracking/",
            "diary": "/api/v1/diary/",
            "list": f"/api/v1/lists/{custom_list.pk}/items/",
        }
        for collection, endpoint in endpoints.items():
            params = {"sort": "rating:imdb", "media_type": MediaTypes.MOVIE.value}
            first = self.client.get(endpoint, params)
            repeated = self.client.get(endpoint, params)
            second = self.client.get(endpoint, {**params, "page": 2})

            self.assertEqual(first.status_code, status.HTTP_200_OK)
            self.assertEqual(first.data["count"], 30)
            first_titles = self._titles(first, collection)
            second_titles = self._titles(second, collection)
            self.assertEqual(first_titles, self._titles(repeated, collection))
            self.assertEqual(first_titles[0], "Movie 29")
            self.assertFalse(set(first_titles) & set(second_titles))
            self.assertEqual(second_titles[-3:], ["Movie 26", "Movie 27", "Movie 28"])

        ascending_params = {
            "media_type": MediaTypes.MOVIE.value,
            "sort": "rating:imdb",
            "direction": "asc",
        }
        ascending_first = self.client.get(endpoints["tracking"], ascending_params)
        ascending = self.client.get(
            endpoints["tracking"],
            {**ascending_params, "page": 2},
        )
        self.assertEqual(self._titles(ascending_first, "tracking")[0], "Movie 00")
        self.assertEqual(
            self._titles(ascending, "tracking")[-3:],
            ["Movie 26", "Movie 27", "Movie 28"],
        )
        mdblist_mock.assert_not_called()
        imdb_mock.assert_not_called()
        metacritic_mock.assert_not_called()
        metadata_mock.assert_not_called()
        refresh_mock.assert_not_called()
        enqueue_mock.assert_not_called()

    def test_external_rating_ties_use_title_item_and_row_identity(self):
        alpha = self._item("tie-alpha", "alpha")
        beta = self._item("tie-beta", "Beta")
        same_first = self._item("tie-same-1", "Same")
        same_second = self._item("tie-same-2", "Same")
        items = [alpha, beta, same_first, same_second]
        Movie.objects.bulk_create([
            Movie(user=self.user, item=item, status=Status.COMPLETED.value)
            for item in items
        ])
        for item in items:
            self._rating(item, "imdb", Decimal(8))
        first_alpha = DiaryEntry.objects.create(user=self.user, item=alpha, consumed_at=self.now)
        second_alpha = DiaryEntry.objects.create(user=self.user, item=alpha, consumed_at=self.now)
        for item in items[1:]:
            DiaryEntry.objects.create(user=self.user, item=item, consumed_at=self.now)

        tracking = self.client.get(
            "/api/v1/tracking/",
            {"media_type": "movie", "sort": "rating:imdb"},
        )
        diary = self.client.get(
            "/api/v1/diary/",
            {"media_type": "movie", "sort": "rating:imdb"},
        )

        self.assertEqual(
            self._titles(tracking, "tracking"),
            ["alpha", "Beta", "Same", "Same"],
        )
        self.assertEqual(
            [result["id"] for result in diary.data["results"][:2]],
            [first_alpha.pk, second_alpha.pk],
        )

    def test_canonical_and_legacy_tokens_read_generic_rows(self):
        generic_high = self._item(
            "generic-high",
            "Generic High",
            imdb_rating=Decimal(1),
            letterboxd_rating=Decimal(1),
            rotten_tomatoes_rating=Decimal(1),
        )
        legacy_high = self._item(
            "legacy-high",
            "Legacy High",
            imdb_rating=Decimal(10),
            letterboxd_rating=Decimal(5),
            rotten_tomatoes_rating=Decimal(100),
        )
        Movie.objects.bulk_create([
            Movie(user=self.user, item=item, status=Status.COMPLETED.value)
            for item in (generic_high, legacy_high)
        ])
        sources = {
            "imdb": (Decimal(9), Decimal(2)),
            "letterboxd": (Decimal("4.5"), Decimal(2)),
            "tomatoes": (Decimal(90), Decimal(20)),
        }
        for source, (high, low) in sources.items():
            self._rating(generic_high, source, high)
            self._rating(legacy_high, source, low)

        tokens = (
            "rating:imdb",
            "imdb_rating",
            "rating:letterboxd",
            "letterboxd_rating",
            "rating:tomatoes",
            "rotten_tomatoes_rating",
        )
        for token in tokens:
            with self.subTest(token=token):
                response = self.client.get(
                    "/api/v1/tracking/",
                    {"media_type": "movie", "sort": token},
                )
                self.assertEqual(response.status_code, status.HTTP_200_OK)
                self.assertEqual(
                    response.data["results"][0]["media"]["title"],
                    "Generic High",
                )

    def test_rating_sort_validation_is_explicit(self):
        item = self._item("validation", "Validation")
        Movie.objects.create(user=self.user, item=item, status=Status.COMPLETED.value)

        for token in (
            "rating",
            "ratings:imdb",
            "rating:",
            "rating:imdb:extra",
            "rating:goodreads",
            "rating:hardcover",
        ):
            with self.subTest(token=token):
                response = self.client.get(
                    "/api/v1/tracking/",
                    {"media_type": "movie", "sort": token},
                )
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertIn("sort", response.data["error"]["fields"])

        fallback = self.client.get(
            "/api/v1/tracking/",
            {"media_type": "movie", "sort": "unknown-base-sort"},
        )
        self.assertEqual(fallback.status_code, status.HTTP_200_OK)

        empty_user = get_user_model().objects.create_user(
            username="empty-rating-scope",
            password="strong-password-123",
        )
        self.client.force_authenticate(empty_user)
        empty = self.client.get(
            "/api/v1/tracking/",
            {"media_type": "movie", "sort": "rating:imdb"},
        )
        self.assertEqual(empty.status_code, status.HTTP_400_BAD_REQUEST)

    def test_filter_options_use_registry_identity_pairs_and_canonical_tokens(self):
        movie = self._item("options-movie", "Movie")
        Movie.objects.create(user=self.user, item=movie, status=Status.COMPLETED.value)
        game = self._item(
            "options-game",
            "Game",
            source=Sources.IGDB.value,
            media_type=MediaTypes.GAME.value,
        )
        Game.objects.create(user=self.user, item=game, status=Status.COMPLETED.value)
        books = CustomList.objects.create(owner=self.user, name="Books")
        openlibrary = self._item(
            "options-openlibrary",
            "Open Library Book",
            source=Sources.OPENLIBRARY.value,
            media_type=MediaTypes.BOOK.value,
        )
        hardcover = self._item(
            "options-hardcover",
            "Hardcover Book",
            source=Sources.HARDCOVER.value,
            media_type=MediaTypes.BOOK.value,
        )
        CustomListItem.objects.bulk_create([
            CustomListItem(custom_list=books, item=openlibrary),
            CustomListItem(custom_list=books, item=hardcover),
        ])
        manual_list = CustomList.objects.create(owner=self.user, name="Manual")
        manual = self._item(
            "options-manual",
            "Manual",
            source=Sources.MANUAL.value,
            media_type=MediaTypes.BOOK.value,
        )
        CustomListItem.objects.create(custom_list=manual_list, item=manual)

        tracking = self.client.get(
            "/api/v1/filter-options/",
            {"scope": "tracking", "media_type": "movie"},
        )
        game_options = self.client.get(
            "/api/v1/filter-options/",
            {"scope": "tracking", "media_type": "game"},
        )
        book_options = self.client.get(
            "/api/v1/filter-options/",
            {"scope": "list", "list_id": books.pk, "media_type": "book"},
        )
        wrong_media = self.client.get(
            "/api/v1/filter-options/",
            {"scope": "list", "list_id": books.pk, "media_type": "movie"},
        )
        manual_options = self.client.get(
            "/api/v1/filter-options/",
            {"scope": "list", "list_id": manual_list.pk, "media_type": "book"},
        )

        base = ["title", "release_date", "your_rating", "average_rating"]
        self.assertEqual(
            [entry["value"] for entry in tracking.data["sorts"]],
            [*base, "rating:tmdb", "rating:imdb", "rating:letterboxd", "rating:tomatoes"],
        )
        self.assertEqual(
            [entry for entry in tracking.data["sorts"] if entry["value"] == "rating:imdb"],
            [{"value": "rating:imdb", "label": "IMDb Rating"}],
        )
        self.assertEqual(
            game_options.data["sorts"],
            [
                *[
                    {"value": value, "label": label}
                    for value, label in (
                        ("title", "Title"),
                        ("release_date", "Release Date"),
                        ("your_rating", "Your Rating"),
                        ("average_rating", "Average Rating"),
                    )
                ],
                {"value": "rating:igdb", "label": "IGDB Rating"},
                {"value": "rating:metacritic", "label": "Metacritic Rating"},
                {"value": "rating:steam", "label": "Steam Rating"},
            ],
        )
        self.assertEqual(
            [entry["value"] for entry in book_options.data["sorts"]],
            [*base, "rating:openlibrary", "rating:hardcover"],
        )
        self.assertEqual([entry["value"] for entry in wrong_media.data["sorts"]], base)
        self.assertEqual([entry["value"] for entry in manual_options.data["sorts"]], base)
        self.assertNotIn("imdb_rating", [entry["value"] for entry in tracking.data["sorts"]])

    def test_steam_rating_sort_is_numeric_with_nulls_last_both_directions(self):
        games = [
            self._item(
                f"steam-{title.lower()}",
                title,
                source=Sources.IGDB.value,
                media_type=MediaTypes.GAME.value,
            )
            for title in ("High", "Low", "Unavailable", "Missing")
        ]
        Game.objects.bulk_create([
            Game(user=self.user, item=item, status=Status.COMPLETED.value)
            for item in games
        ])
        self._rating(games[0], "steam", Decimal(95))
        self._rating(games[1], "steam", Decimal(72))
        self._rating(
            games[2],
            "steam",
            status_value=ExternalRating.Status.UNAVAILABLE,
        )

        descending = self.client.get(
            "/api/v1/tracking/",
            {"media_type": "game", "sort": "rating:steam"},
        )
        ascending = self.client.get(
            "/api/v1/tracking/",
            {
                "media_type": "game",
                "sort": "rating:steam",
                "direction": "asc",
            },
        )

        self.assertEqual(
            self._titles(descending, "tracking"),
            ["High", "Low", "Missing", "Unavailable"],
        )
        self.assertEqual(
            self._titles(ascending, "tracking"),
            ["Low", "High", "Missing", "Unavailable"],
        )

    def test_external_sort_preserves_personal_rating_ranges_and_collection_scope(self):
        personal_high = self._item("personal-high", "Personal High")
        external_high = self._item("external-high", "External High")
        out_of_scope = self._item("out-of-scope", "Out Of Scope")
        Movie.objects.bulk_create([
            Movie(
                user=self.user,
                item=personal_high,
                status=Status.COMPLETED.value,
                score=Decimal(8),
            ),
            Movie(
                user=self.user,
                item=external_high,
                status=Status.PLANNING.value,
                score=Decimal(2),
            ),
        ])
        self._rating(personal_high, "imdb", Decimal(2))
        self._rating(external_high, "imdb", Decimal(9))
        self._rating(out_of_scope, "imdb", Decimal(10))
        DiaryEntry.objects.bulk_create([
            DiaryEntry(
                user=self.user,
                item=personal_high,
                consumed_at=self.now,
                rating=Decimal(8),
            ),
            DiaryEntry(
                user=self.user,
                item=external_high,
                consumed_at=self.now,
                rating=Decimal(2),
            ),
        ])
        custom_list = CustomList.objects.create(owner=self.user, name="Scoped")
        CustomListItem.objects.bulk_create([
            CustomListItem(custom_list=custom_list, item=personal_high),
            CustomListItem(custom_list=custom_list, item=external_high),
        ])

        requests = {
            "tracking": (
                "/api/v1/tracking/",
                {"media_type": "movie", "sort": "rating:imdb", "rating_min": "7"},
            ),
            "diary": (
                "/api/v1/diary/",
                {"media_type": "movie", "sort": "rating:imdb", "rating_min": "7"},
            ),
            "list": (
                f"/api/v1/lists/{custom_list.pk}/items/",
                {"media_type": "movie", "sort": "rating:imdb", "rating_min": "7"},
            ),
        }
        for collection, (endpoint, params) in requests.items():
            response = self.client.get(endpoint, params)
            self.assertEqual(response.status_code, status.HTTP_200_OK)
            self.assertEqual(self._titles(response, collection), ["Personal High"])

        status_and_search = self.client.get(
            "/api/v1/tracking/",
            {
                "media_type": "movie",
                "status": Status.COMPLETED.value,
                "q": "Personal",
                "sort": "rating:imdb",
            },
        )
        self.assertEqual(self._titles(status_and_search, "tracking"), ["Personal High"])
        for collection, endpoint in (
            ("diary", "/api/v1/diary/"),
            ("list", f"/api/v1/lists/{custom_list.pk}/items/"),
        ):
            response = self.client.get(
                endpoint,
                {"media_type": "movie", "q": "Personal", "sort": "rating:imdb"},
            )
            self.assertEqual(self._titles(response, collection), ["Personal High"])

    def test_external_rating_query_uses_filtered_join_and_existing_unique_index(self):
        item = self._item("query-plan", "Query Plan")
        Movie.objects.create(user=self.user, item=item, status=Status.COMPLETED.value)
        self._rating(item, "imdb", Decimal(8))
        queryset = Movie.objects.filter(user=self.user)
        ordered = filter_service.order_queryset(
            queryset,
            {"sort": "rating:imdb"},
            rating_scope_queryset=queryset,
        )

        sql = str(ordered.query)
        self.assertIn('LEFT OUTER JOIN "app_externalrating"', sql)
        self.assertIn("external_rating_sort", sql)
        self.assertNotIn("imdb_rating", sql)
        postgres = DatabaseWrapper({"NAME": "unused"}, alias="postgresql-shaped")
        postgres_sql, _params = ordered.query.get_compiler(connection=postgres).as_sql()
        self.assertIn('LEFT OUTER JOIN "app_externalrating"', postgres_sql)
        self.assertIn("NULLS LAST", postgres_sql)
        if connection.vendor == "sqlite":
            plan = ordered.explain()
            self.assertIn("sqlite_autoindex_app_externalrating_1", plan)
            self.assertIn("USE TEMP B-TREE FOR ORDER BY", plan)
