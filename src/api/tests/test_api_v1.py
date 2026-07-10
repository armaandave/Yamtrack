from datetime import UTC, datetime
from importlib import import_module
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from api.serializers.common import media_summary_from_item
from api.services.media import external_ratings
from app.models import (
    TV,
    Anime,
    Book,
    CustomBackdropPreference,
    CustomPosterPreference,
    DiaryEntry,
    Item,
    ItemFilterFacet,
    MediaLike,
    MediaTypes,
    Movie,
    Season,
    Sources,
    Status,
)
from app.services import set_media_like, update_diary_entry_tags
from lists.models import CustomList, CustomListItem
from social.models import Activity, ContentLike, ProgressChange, SocialAuditLog


class ApiV1FoundationTests(TestCase):
    """Smoke tests for the v1 mobile API foundation."""

    def setUp(self):
        cache.clear()
        self.client = APIClient()

    def test_health_is_public(self):
        response = self.client.get("/api/v1/health/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], "ok")

    def test_meta_is_public(self):
        response = self.client.get("/api/v1/meta/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("movie", response.data["media_types"])
        self.assertIn("Completed", response.data["status_choices"])

    def test_register_returns_tokens_and_user(self):
        response = self.client.post(
            "/api/v1/auth/register/",
            {
                "username": "iosuser",
                "email": "ios@example.com",
                "password": "strong-password-123",
                "password_confirm": "strong-password-123",
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertIn("access", response.data)
        self.assertIn("refresh", response.data)
        self.assertEqual(response.data["user"]["username"], "iosuser")

    def test_login_and_me(self):
        get_user_model().objects.create_user(
            username="mobile",
            email="mobile@example.com",
            password="strong-password-123",
        )

        login = self.client.post(
            "/api/v1/auth/login/",
            {
                "username_or_email": "mobile@example.com",
                "password": "strong-password-123",
            },
            format="json",
        )
        self.assertEqual(login.status_code, status.HTTP_200_OK)

        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {login.data['access']}")
        response = self.client.get("/api/v1/me/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["username"], "mobile")

    def test_me_includes_profile_menu_counts(self):
        user = get_user_model().objects.create_user(username="profile-counts", password="strong-password-123")
        completed = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Completed",
        )
        planned = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="551",
            title="Planned",
        )
        Movie.objects.bulk_create(
            [
                Movie(user=user, item=completed, status=Status.IN_PROGRESS.value),
                Movie(user=user, item=planned, status=Status.PLANNING.value),
            ]
        )
        CustomList.objects.create(owner=user, name="Favorites")
        reviewed = DiaryEntry.objects.create(
            user=user,
            item=completed,
            consumed_at=timezone.now(),
            review="Good.",
            liked=True,
        )
        MediaLike.objects.create(user=user, item=completed)
        update_diary_entry_tags(reviewed, ["great"])
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/me/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        counts = response.data["counts"]
        self.assertEqual(counts["library_items"], 1)
        self.assertEqual(counts["reviews"], 1)
        self.assertEqual(counts["planned_items"], 1)
        self.assertEqual(counts["liked_items"], 1)
        self.assertEqual(counts["tags"], 1)
        self.assertEqual(counts["lists"], 1)

    def test_lists_include_ordered_capped_preview_items(self):
        user = get_user_model().objects.create_user(username="list-previews", password="strong-password-123")
        custom_list = CustomList.objects.create(owner=user, name="Weekend Watchlist")
        items = self._create_movie_items(13, title_prefix="Preview", media_id_prefix="preview")
        for index, item in enumerate(items):
            CustomListItem.objects.create(
                custom_list=custom_list,
                item=item,
                position=13 - index,
            )
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/lists/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        result = response.data["results"][0]
        self.assertNotIn("items", result)
        self.assertEqual(result["items_count"], 13)
        self.assertEqual(len(result["preview_items"]), 12)
        self.assertEqual(result["preview_items"][0]["title"], "Preview 12")
        self.assertEqual(result["preview_items"][-1]["title"], "Preview 01")
        self.assertEqual(result["preview_items"][0]["poster_url"], result["preview_items"][0]["image_url"])

    @patch("app.providers.services.get_media_metadata")
    def test_lists_preview_items_do_not_resolve_backdrops(self, metadata_mock):
        user = get_user_model().objects.create_user(username="list-preview-backdrop", password="strong-password-123")
        custom_list = CustomList.objects.create(owner=user, name="Weekend Watchlist")
        item = self._create_movie_items(1, title_prefix="Preview", media_id_prefix="preview-backdrop")[0]
        CustomListItem.objects.create(custom_list=custom_list, item=item)
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/lists/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIsNone(response.data["results"][0]["preview_items"][0]["backdrop_url"])
        metadata_mock.assert_not_called()

    def test_list_detail_can_skip_items_for_fast_mobile_load(self):
        user = get_user_model().objects.create_user(username="list-detail-fast", password="strong-password-123")
        custom_list = CustomList.objects.create(owner=user, name="Watchlist")
        item = self._create_movie_items(1, title_prefix="Fast", media_id_prefix="fast-list")[0]
        CustomListItem.objects.create(custom_list=custom_list, item=item)
        self.client.force_authenticate(user)

        response = self.client.get(f"/api/v1/lists/{custom_list.id}/", {"include_items": "false"})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["items_count"], 1)
        self.assertNotIn("items", response.data)

    @patch("app.providers.services.get_media_metadata")
    def test_list_detail_items_do_not_resolve_provider_backdrops(self, metadata_mock):
        user = get_user_model().objects.create_user(username="list-detail-no-provider", password="strong-password-123")
        custom_list = CustomList.objects.create(owner=user, name="Watchlist")
        item = self._create_movie_items(1, title_prefix="Backdrop", media_id_prefix="no-provider-backdrop")[0]
        CustomListItem.objects.create(custom_list=custom_list, item=item)
        self.client.force_authenticate(user)

        response = self.client.get(f"/api/v1/lists/{custom_list.id}/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIsNone(response.data["items"][0]["backdrop_url"])
        metadata_mock.assert_not_called()

    @patch("app.providers.services.get_media_metadata")
    def test_list_items_include_same_user_backdrop_as_media_detail(self, metadata_mock):
        user = get_user_model().objects.create_user(username="list-backdrop", password="strong-password-123")
        custom_list = CustomList.objects.create(owner=user, name="Watchlist")
        item = self._create_movie_items(1, title_prefix="Backdrop", media_id_prefix="backdrop")[0]
        CustomListItem.objects.create(custom_list=custom_list, item=item)
        CustomBackdropPreference.objects.create(
            user=user,
            item=item,
            custom_image_url="https://example.com/custom-backdrop.jpg",
        )
        metadata_mock.return_value = {"backdrop_path": "/default-backdrop.jpg"}
        self.client.force_authenticate(user)

        response = self.client.get(f"/api/v1/lists/{custom_list.id}/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        media = response.data["items"][0]
        self.assertIsNone(media["backdrop_url"])
        self.assertEqual(media["custom_backdrop_url"], "https://example.com/custom-backdrop.jpg")
        metadata_mock.assert_not_called()

    def test_ranked_list_reorder_updates_positions(self):
        user = get_user_model().objects.create_user(username="list-reorder", password="strong-password-123")
        custom_list = CustomList.objects.create(owner=user, name="Ranked", is_ranked=True)
        items = self._create_movie_items(3, title_prefix="Ranked", media_id_prefix="ranked")
        for index, item in enumerate(items, start=1):
            CustomListItem.objects.create(custom_list=custom_list, item=item, position=index)
        self.client.force_authenticate(user)

        response = self.client.patch(
            f"/api/v1/lists/{custom_list.id}/items/reorder/",
            {"item_ids": [items[2].id, items[0].id, items[1].id]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual([item["ref"]["item_id"] for item in response.data["items"]], [items[2].id, items[0].id, items[1].id])
        self.assertEqual(
            list(CustomListItem.objects.filter(custom_list=custom_list).values_list("item_id", "position")),
            [(items[2].id, 1), (items[0].id, 2), (items[1].id, 3)],
        )

    def test_reorder_rejects_wrong_item_set(self):
        user = get_user_model().objects.create_user(username="list-reorder-bad", password="strong-password-123")
        custom_list = CustomList.objects.create(owner=user, name="Ranked")
        items = self._create_movie_items(2, title_prefix="Ranked Bad", media_id_prefix="ranked-bad")
        for item in items:
            CustomListItem.objects.create(custom_list=custom_list, item=item)
        self.client.force_authenticate(user)

        response = self.client.patch(
            f"/api/v1/lists/{custom_list.id}/items/reorder/",
            {"item_ids": [items[0].id]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_reorder_requires_edit_permission(self):
        owner = get_user_model().objects.create_user(username="list-reorder-owner", password="strong-password-123")
        other = get_user_model().objects.create_user(username="list-reorder-other", password="strong-password-123")
        custom_list = CustomList.objects.create(owner=owner, name="Ranked")
        item = self._create_movie_items(1, title_prefix="Ranked Forbidden", media_id_prefix="ranked-forbidden")[0]
        CustomListItem.objects.create(custom_list=custom_list, item=item)
        self.client.force_authenticate(other)

        response = self.client.patch(
            f"/api/v1/lists/{custom_list.id}/items/reorder/",
            {"item_ids": [item.id]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_ranked_add_assigns_next_position_and_normal_add_leaves_null(self):
        user = get_user_model().objects.create_user(username="list-add-position", password="strong-password-123")
        ranked = CustomList.objects.create(owner=user, name="Ranked", is_ranked=True)
        normal = CustomList.objects.create(owner=user, name="Normal")
        existing, ranked_item, normal_item = self._create_movie_items(3, title_prefix="Add", media_id_prefix="add")
        CustomListItem.objects.create(custom_list=ranked, item=existing, position=4)
        self.client.force_authenticate(user)

        ranked_response = self.client.post(
            f"/api/v1/lists/{ranked.id}/items/",
            {"ref": {"source": ranked_item.source, "media_type": ranked_item.media_type, "media_id": ranked_item.media_id}},
            format="json",
        )
        normal_response = self.client.post(
            f"/api/v1/lists/{normal.id}/items/",
            {"ref": {"source": normal_item.source, "media_type": normal_item.media_type, "media_id": normal_item.media_id}},
            format="json",
        )

        self.assertEqual(ranked_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(normal_response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(CustomListItem.objects.get(custom_list=ranked, item=ranked_item).position, 5)
        self.assertIsNone(CustomListItem.objects.get(custom_list=normal, item=normal_item).position)

    def test_ranked_delete_renumbers_remaining_items(self):
        user = get_user_model().objects.create_user(username="list-delete-ranked", password="strong-password-123")
        custom_list = CustomList.objects.create(owner=user, name="Ranked", is_ranked=True)
        items = self._create_movie_items(3, title_prefix="Delete", media_id_prefix="delete")
        for index, item in enumerate(items, start=1):
            CustomListItem.objects.create(custom_list=custom_list, item=item, position=index)
        self.client.force_authenticate(user)

        response = self.client.delete(f"/api/v1/lists/{custom_list.id}/items/{items[1].id}/")

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertEqual(
            list(CustomListItem.objects.filter(custom_list=custom_list).values_list("item_id", "position")),
            [(items[0].id, 1), (items[2].id, 2)],
        )

    def test_mode_switch_assigns_and_preserves_positions(self):
        user = get_user_model().objects.create_user(username="list-mode-switch", password="strong-password-123")
        custom_list = CustomList.objects.create(owner=user, name="Mode")
        items = self._create_movie_items(3, title_prefix="Mode", media_id_prefix="mode")
        CustomListItem.objects.create(custom_list=custom_list, item=items[0], position=2)
        CustomListItem.objects.create(custom_list=custom_list, item=items[1])
        CustomListItem.objects.create(custom_list=custom_list, item=items[2])
        self.client.force_authenticate(user)

        ranked = self.client.patch(f"/api/v1/lists/{custom_list.id}/", {"is_ranked": True}, format="json")
        normal = self.client.patch(f"/api/v1/lists/{custom_list.id}/", {"is_ranked": False}, format="json")
        detail = self.client.get(f"/api/v1/lists/{custom_list.id}/")

        self.assertEqual(ranked.status_code, status.HTTP_200_OK)
        self.assertEqual(normal.status_code, status.HTTP_200_OK)
        self.assertFalse(detail.data["is_ranked"])
        self.assertEqual([item["position"] for item in detail.data["items"]], [1, 2, 3])
        self.assertEqual([item["ref"]["item_id"] for item in detail.data["items"]], [items[0].id, items[1].id, items[2].id])

    def test_ranked_backfill_migration_marks_positioned_lists(self):
        user = get_user_model().objects.create_user(username="list-migration", password="strong-password-123")
        custom_list = CustomList.objects.create(owner=user, name="Imported", is_ranked=False)
        item = self._create_movie_items(1, title_prefix="Imported", media_id_prefix="imported")[0]
        CustomListItem.objects.create(custom_list=custom_list, item=item, position=1)

        import_module("lists.migrations.0005_customlist_is_ranked").backfill_ranked_lists(import_module("django.apps").apps, None)

        custom_list.refresh_from_db()
        self.assertTrue(custom_list.is_ranked)

    def test_lists_membership_query_returns_has_item(self):
        user = get_user_model().objects.create_user(username="list-membership", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="membership",
            title="Membership",
        )
        with_item = CustomList.objects.create(owner=user, name="With")
        without_item = CustomList.objects.create(owner=user, name="Without")
        CustomListItem.objects.create(custom_list=with_item, item=item)
        self.client.force_authenticate(user)

        response = self.client.get(
            "/api/v1/lists/",
            {
                "ref[source]": Sources.TMDB.value,
                "ref[media_type]": MediaTypes.MOVIE.value,
                "ref[media_id]": "membership",
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            {result["name"]: result["has_item"] for result in response.data["results"]},
            {with_item.name: True, without_item.name: False},
        )

    def test_list_items_endpoint_filters_and_sorts_mixed_media(self):
        user = get_user_model().objects.create_user(username="list-item-filters", password="strong-password-123")
        custom_list = CustomList.objects.create(owner=user, name="Filtered List")
        low = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="list-low",
            title="Low Drama",
            release_year=2001,
        )
        high = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="list-high",
            title="High Drama",
            release_year=2022,
        )
        other = Item.objects.create(
            source=Sources.HARDCOVER.value,
            media_type=MediaTypes.BOOK.value,
            media_id="list-book",
            title="Book",
            release_year=2022,
        )
        ItemFilterFacet.objects.bulk_create(
            [
                ItemFilterFacet(item=low, facet_type="genre", value="Drama"),
                ItemFilterFacet(item=high, facet_type="genre", value="Drama"),
                ItemFilterFacet(item=high, facet_type="genre", value="Comedy"),
                ItemFilterFacet(item=other, facet_type="genre", value="Fantasy"),
            ]
        )
        CustomListItem.objects.bulk_create(
            [
                CustomListItem(custom_list=custom_list, item=low),
                CustomListItem(custom_list=custom_list, item=high),
                CustomListItem(custom_list=custom_list, item=other),
            ]
        )
        Movie.objects.bulk_create(
            [
                Movie(user=user, item=low, status=Status.COMPLETED.value, score="4.0"),
                Movie(user=user, item=high, status=Status.COMPLETED.value, score="9.0"),
            ]
        )
        Book.objects.create(user=user, item=other, status=Status.PLANNING.value)
        self.client.force_authenticate(user)

        response = self.client.get(
            f"/api/v1/lists/{custom_list.id}/items/",
            {"genre": "Drama", "sort": "your_rating"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 2)
        self.assertEqual(
            [result["title"] for result in response.data["results"]],
            ["High Drama", "Low Drama"],
        )
        self.assertEqual(response.data["results"][0]["your_rating"], "9.0")

        response = self.client.get(
            f"/api/v1/lists/{custom_list.id}/items/",
            {"genre": "Drama", "exclude_genre": "Comedy", "sort": "your_rating"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [result["title"] for result in response.data["results"]],
            ["Low Drama"],
        )

    def test_filter_options_returns_available_facets_for_scope(self):
        user = get_user_model().objects.create_user(username="filter-options", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="options",
            title="Options",
            release_year=2024,
        )
        excluded = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="excluded-options",
            title="Excluded Options",
            release_year=2023,
        )
        ItemFilterFacet.objects.create(item=item, facet_type="language", value="English")
        ItemFilterFacet.objects.create(item=excluded, facet_type="language", value="French")
        Movie.objects.bulk_create([
            Movie(user=user, item=item, status=Status.COMPLETED.value),
            Movie(user=user, item=excluded, status=Status.COMPLETED.value),
        ])
        self.client.force_authenticate(user)

        response = self.client.get(
            "/api/v1/filter-options/",
            {"scope": "tracking", "media_type": MediaTypes.MOVIE.value, "exclude_language": "French"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn({"value": "release_date", "label": "Release Date"}, response.data["sorts"])
        self.assertEqual(
            response.data["languages"],
            [{"value": "English", "label": "English"}, {"value": "French", "label": "French"}],
        )
        self.assertEqual(response.data["years"], [2024, 2023])

    def test_tracking_list_paginates_before_serializing_movies(self):
        user = get_user_model().objects.create_user(username="tracking-pages", password="strong-password-123")
        self._create_movies(user, 30)
        self.client.force_authenticate(user)

        with patch("api.views.tracking.media_summary_from_item", wraps=media_summary_from_item) as summary_mock:
            response = self.client.get("/api/v1/tracking/?media_type=movie")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 30)
        self.assertEqual(len(response.data["results"]), 25)
        self.assertIsNotNone(response.data["next"])
        self.assertIsNone(response.data["previous"])
        self.assertEqual(summary_mock.call_count, 25)

    def test_tracking_list_defaults_to_newest_release_date(self):
        user = get_user_model().objects.create_user(username="tracking-default-sort", password="strong-password-123")
        older = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="older-default-sort",
            title="A Older",
            release_date=datetime(1999, 1, 1, tzinfo=UTC).date(),
        )
        newer = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="newer-default-sort",
            title="Z Newer",
            release_date=datetime(2024, 1, 1, tzinfo=UTC).date(),
        )
        Movie.objects.bulk_create(
            [
                Movie(user=user, item=older, status=Status.COMPLETED.value),
                Movie(user=user, item=newer, status=Status.COMPLETED.value),
            ]
        )
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/tracking/?media_type=movie")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual([item["media"]["title"] for item in response.data["results"]], ["Z Newer", "A Older"])

    def test_tracking_list_includes_viewer_custom_posters(self):
        user = get_user_model().objects.create_user(username="tracking-custom-posters", password="strong-password-123")
        cases = [
            (MediaTypes.MOVIE.value, Sources.TMDB.value, Movie, "custom-movie"),
            (MediaTypes.TV.value, Sources.TMDB.value, TV, "custom-tv"),
            (MediaTypes.BOOK.value, Sources.OPENLIBRARY.value, Book, "custom-book"),
        ]
        for media_type, source, model, media_id in cases:
            item = Item.objects.create(
                source=source,
                media_type=media_type,
                media_id=media_id,
                title=f"{media_type} custom poster",
                image=f"https://example.com/{media_id}-original.jpg",
            )
            model.objects.bulk_create([model(user=user, item=item, status=Status.COMPLETED.value)])
            CustomPosterPreference.objects.create(
                user=user,
                item=item,
                custom_image_url=f"https://example.com/{media_id}-custom.jpg",
            )
        self.client.force_authenticate(user)

        for media_type, _source, _model, media_id in cases:
            response = self.client.get("/api/v1/tracking/", {"media_type": media_type})

            self.assertEqual(response.status_code, status.HTTP_200_OK)
            self.assertEqual(response.data["results"][0]["media"]["custom_poster_url"], f"https://example.com/{media_id}-custom.jpg")

    def test_tracking_list_page_two_returns_next_movie_page(self):
        user = get_user_model().objects.create_user(username="tracking-page-two", password="strong-password-123")
        self._create_movies(user, 30)
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/tracking/?media_type=movie&page=2")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 30)
        self.assertEqual(len(response.data["results"]), 5)
        self.assertIsNone(response.data["next"])
        self.assertIsNotNone(response.data["previous"])

    def test_tracking_list_status_filters_planning_items(self):
        user = get_user_model().objects.create_user(username="tracking-planning", password="strong-password-123")
        completed_items = self._create_movie_items(3, title_prefix="Completed", media_id_prefix="c")
        planned_items = self._create_movie_items(4, title_prefix="Planned", media_id_prefix="p")
        Movie.objects.bulk_create(
            [Movie(user=user, item=item, status=Status.COMPLETED.value) for item in completed_items]
            + [Movie(user=user, item=item, status=Status.PLANNING.value) for item in planned_items]
        )
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/tracking/?media_type=movie&status=Planning")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 4)
        self.assertEqual(len(response.data["results"]), 4)
        self.assertEqual(
            {item["tracking"]["status"] for item in response.data["results"]},
            {Status.PLANNING.value},
        )

    def test_tracking_filters_cached_facets_and_sorts_without_provider_calls(self):
        user = get_user_model().objects.create_user(username="tracking-filters", password="strong-password-123")
        old_drama = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="old-drama",
            title="Old Drama",
            release_year=1999,
            release_date=datetime(1999, 1, 1, tzinfo=UTC).date(),
            imdb_rating="7.0",
        )
        new_drama = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="new-drama",
            title="New Drama",
            release_year=2024,
            release_date=datetime(2024, 1, 1, tzinfo=UTC).date(),
            imdb_rating="8.5",
        )
        comedy = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="comedy",
            title="Comedy",
            release_year=2024,
            release_date=datetime(2024, 6, 1, tzinfo=UTC).date(),
        )
        ItemFilterFacet.objects.bulk_create(
            [
                ItemFilterFacet(item=old_drama, facet_type="genre", value="Drama"),
                ItemFilterFacet(item=new_drama, facet_type="genre", value="Drama"),
                ItemFilterFacet(item=comedy, facet_type="genre", value="Comedy"),
            ]
        )
        Movie.objects.bulk_create(
            [
                Movie(user=user, item=old_drama, status=Status.COMPLETED.value, score="6.0"),
                Movie(user=user, item=new_drama, status=Status.COMPLETED.value, score="9.0"),
                Movie(user=user, item=comedy, status=Status.COMPLETED.value, score="8.0"),
            ]
        )
        self.client.force_authenticate(user)

        with patch("app.providers.services.get_media_metadata") as metadata_mock:
            response = self.client.get(
                "/api/v1/tracking/",
                {
                    "media_type": MediaTypes.MOVIE.value,
                    "genre": "Drama",
                    "year_min": "2000",
                    "sort": "imdb_rating",
                },
            )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(metadata_mock.called)
        self.assertEqual(response.data["count"], 1)
        self.assertEqual(response.data["results"][0]["media"]["title"], "New Drama")

    @patch("app.providers.services.get_media_metadata")
    def test_tracking_backfills_filter_metadata_before_sorting_full_collection(self, metadata_mock):
        user = get_user_model().objects.create_user(username="tracking-backfill", password="strong-password-123")
        items = self._create_movie_items(30, title_prefix="Backfill", media_id_prefix="backfill")
        Movie.objects.bulk_create(
            [Movie(user=user, item=item, status=Status.COMPLETED.value) for item in items],
        )
        newest = items[-1]

        def metadata_for(_media_type, media_id, _source, **_kwargs):
            release_date = "2030-01-01" if media_id == newest.media_id else "1990-01-01"
            return {
                "title": media_id,
                "release_date": release_date,
                "details": {"runtime": "1h 30m"},
                "genres": [{"name": "Drama"}],
                "languages": [{"english_name": "English"}],
            }

        metadata_mock.side_effect = metadata_for
        self.client.force_authenticate(user)

        response = self.client.get(
            "/api/v1/tracking/",
            {
                "media_type": MediaTypes.MOVIE.value,
                "sort": "release_date",
                "direction": "desc",
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 30)
        self.assertEqual(response.data["results"][0]["media"]["title"], newest.title)
        newest.refresh_from_db()
        self.assertEqual(newest.release_year, 2030)
        self.assertEqual(newest.runtime_minutes, 90)

    def test_tracking_status_tracked_excludes_planning_before_pagination(self):
        user = get_user_model().objects.create_user(username="tracking-status-tracked", password="strong-password-123")
        planned_items = self._create_movie_items(10, title_prefix="A Planned", media_id_prefix="planned-status")
        completed_items = self._create_movie_items(30, title_prefix="B Completed", media_id_prefix="completed-status")
        Movie.objects.bulk_create(
            [Movie(user=user, item=item, status=Status.PLANNING.value) for item in planned_items]
            + [Movie(user=user, item=item, status=Status.COMPLETED.value) for item in completed_items],
        )
        self.client.force_authenticate(user)

        response = self.client.get(
            "/api/v1/tracking/",
            {
                "media_type": MediaTypes.MOVIE.value,
                "status": "tracked",
                "sort": "title",
                "direction": "asc",
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 30)
        self.assertEqual(len(response.data["results"]), 25)
        self.assertTrue(
            all(result["tracking"]["status"] != Status.PLANNING.value for result in response.data["results"]),
        )

    def test_tracking_filters_release_status_and_movie_length(self):
        user = get_user_model().objects.create_user(username="tracking-release-length", password="strong-password-123")
        released_feature = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="released-feature",
            title="Released Feature",
            release_date=datetime(2024, 1, 1, tzinfo=UTC).date(),
            release_year=2024,
            runtime_minutes=90,
        )
        released_short = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="released-short",
            title="Released Short",
            release_date=datetime(2024, 1, 1, tzinfo=UTC).date(),
            release_year=2024,
            runtime_minutes=12,
        )
        unreleased_feature = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="unreleased-feature",
            title="Unreleased Feature",
            release_date=datetime(2099, 1, 1, tzinfo=UTC).date(),
            release_year=2099,
            runtime_minutes=90,
        )
        Movie.objects.bulk_create(
            [
                Movie(user=user, item=released_feature, status=Status.COMPLETED.value),
                Movie(user=user, item=released_short, status=Status.COMPLETED.value),
                Movie(user=user, item=unreleased_feature, status=Status.PLANNING.value),
            ],
        )
        self.client.force_authenticate(user)

        released = self.client.get(
            "/api/v1/tracking/",
            {"media_type": MediaTypes.MOVIE.value, "release_status": "released", "length": "feature"},
        )
        short = self.client.get(
            "/api/v1/tracking/",
            {"media_type": MediaTypes.MOVIE.value, "length": "short"},
        )
        unreleased = self.client.get(
            "/api/v1/tracking/",
            {"media_type": MediaTypes.MOVIE.value, "release_status": "unreleased"},
        )

        self.assertEqual(released.status_code, status.HTTP_200_OK)
        self.assertEqual([result["media"]["title"] for result in released.data["results"]], ["Released Feature"])
        self.assertEqual([result["media"]["title"] for result in short.data["results"]], ["Released Short"])
        self.assertEqual([result["media"]["title"] for result in unreleased.data["results"]], ["Unreleased Feature"])

    def test_tracking_sorts_by_public_average_rating(self):
        user = get_user_model().objects.create_user(username="tracking-average", password="strong-password-123")
        low = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="avg-low",
            title="Low",
        )
        high = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="avg-high",
            title="High",
        )
        Movie.objects.bulk_create(
            [
                Movie(user=user, item=low, status=Status.COMPLETED.value),
                Movie(user=user, item=high, status=Status.COMPLETED.value),
            ]
        )
        DiaryEntry.objects.create(user=user, item=low, consumed_at=timezone.now(), rating="4.0")
        DiaryEntry.objects.create(user=user, item=high, consumed_at=timezone.now(), rating="9.0")
        DiaryEntry.objects.create(
            user=user,
            item=low,
            consumed_at=timezone.now(),
            rating="10.0",
            visibility="private",
        )
        self.client.force_authenticate(user)

        response = self.client.get(
            "/api/v1/tracking/",
            {"media_type": MediaTypes.MOVIE.value, "sort": "average_rating"},
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [result["media"]["title"] for result in response.data["results"]],
            ["High", "Low"],
        )

    @patch("app.models.providers.services.get_media_metadata", return_value={"max_progress": None})
    def test_tracking_patch_records_progress_change(self, _metadata_mock):
        user = get_user_model().objects.create_user(username="tracking-progress-change", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.MAL.value,
            media_type=MediaTypes.ANIME.value,
            media_id="progress-change",
            title="Progress Change",
        )
        Anime.objects.create(user=user, item=item, status=Status.IN_PROGRESS.value, progress=10)
        self.client.force_authenticate(user)

        response = self.client.patch(
            "/api/v1/tracking/mal/anime/progress-change/",
            {"status": Status.IN_PROGRESS.value, "progress": 12},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        change = ProgressChange.objects.get(actor=user, item=item)
        self.assertEqual(change.previous_progress["value"], 10)
        self.assertEqual(change.current_progress["value"], 12)
        self.assertEqual(response.data["latest_progress_change"]["id"], change.id)
        self.assertEqual(response.data["latest_progress_change"]["current"]["value"], 12)
        self.assertTrue(
            Activity.objects.filter(
                actor=user,
                verb="progress_updated",
                target_type="progress_change",
                target_id=change.id,
                item=item,
            ).exists()
        )

    @patch("app.models.providers.services.get_media_metadata", return_value={"max_progress": None})
    def test_unchanged_progress_does_not_record_progress_change(self, _metadata_mock):
        user = get_user_model().objects.create_user(username="tracking-progress-same", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.MAL.value,
            media_type=MediaTypes.ANIME.value,
            media_id="progress-same",
            title="Progress Same",
        )
        Anime.objects.create(user=user, item=item, status=Status.IN_PROGRESS.value, progress=10)
        self.client.force_authenticate(user)

        response = self.client.patch(
            "/api/v1/tracking/mal/anime/progress-same/",
            {"status": Status.IN_PROGRESS.value, "progress": 10},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(ProgressChange.objects.filter(actor=user, item=item).exists())

    @patch("app.models.providers.services.get_media_metadata", return_value={"max_progress": None})
    @patch("api.services.tracking.provider_services.get_media_metadata")
    def test_new_tracking_has_no_progress_change(self, metadata_mock, _progress_mock):
        user = get_user_model().objects.create_user(username="tracking-progress-new", password="strong-password-123")
        metadata_mock.return_value = {
            "title": "Progress New",
            "image": "https://example.com/progress-new.jpg",
            "max_progress": None,
        }
        self.client.force_authenticate(user)

        response = self.client.patch(
            "/api/v1/tracking/mal/anime/progress-new/",
            {"status": Status.IN_PROGRESS.value, "progress": 5},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["progress"]["value"], 5)
        self.assertIsNone(response.data["latest_progress_change"])
        self.assertFalse(ProgressChange.objects.filter(actor=user).exists())

    def test_book_progress_records_progress_change_and_tracking_list_exposes_latest(self):
        user = get_user_model().objects.create_user(username="book-progress-change", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.OPENLIBRARY.value,
            media_type=MediaTypes.BOOK.value,
            media_id="book-progress-change",
            title="Book Progress Change",
            total_pages=100,
        )
        Book.objects.create(user=user, item=item, status=Status.IN_PROGRESS.value, progress=42)
        self.client.force_authenticate(user)

        response = self.client.post(
            "/api/v1/tracking/openlibrary/book/book-progress-change/progress/",
            {"progress_type": "percentage", "value": "58"},
            format="json",
        )
        list_response = self.client.get("/api/v1/tracking/?media_type=book&status=In progress")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        change = ProgressChange.objects.get(actor=user, item=item)
        self.assertEqual(change.previous_progress["value"], 42)
        self.assertEqual(change.current_progress["value"], 58)
        self.assertEqual(response.data["latest_progress_change"]["previous"]["value"], 42)
        self.assertEqual(list_response.status_code, status.HTTP_200_OK)
        self.assertEqual(list_response.data["results"][0]["tracking"]["latest_progress_change"]["id"], change.id)

    @patch("app.models.providers.services.get_media_metadata")
    def test_episode_watch_records_season_progress_change(self, metadata_mock):
        user = get_user_model().objects.create_user(username="season-progress-change", password="strong-password-123")
        tv_item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.TV.value,
            media_id="season-progress-change",
            title="Season Progress Change",
        )
        season_item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.SEASON.value,
            media_id="season-progress-change",
            season_number=1,
            title="Season Progress Change",
        )
        tv = TV.objects.create(user=user, item=tv_item, status=Status.IN_PROGRESS.value)
        Season.objects.create(user=user, item=season_item, related_tv=tv, status=Status.IN_PROGRESS.value)
        metadata_mock.side_effect = lambda media_type, *_args: {
            "season": {
                "episodes": [
                    {"episode_number": 1, "air_date": "2020-01-01"},
                    {"episode_number": 2, "air_date": "2020-01-08"},
                ]
            },
            "tv_with_seasons": {
                "season/1": {
                    "episodes": [
                        {"episode_number": 1, "air_date": "2020-01-01"},
                        {"episode_number": 2, "air_date": "2020-01-08"},
                    ]
                }
            },
        }[media_type]
        self.client.force_authenticate(user)

        response = self.client.post(
            "/api/v1/tracking/tmdb/tv/season-progress-change/seasons/1/episodes/1/watch/",
            {},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        change = ProgressChange.objects.get(actor=user, item=season_item)
        self.assertEqual(change.previous_progress["value"], 0)
        self.assertEqual(change.current_progress["value"], 1)
        self.assertEqual(response.data["latest_progress_change"]["current"]["value"], 1)

    def test_user_activity_includes_progress_updated_payload(self):
        user = get_user_model().objects.create_user(username="progress-activity", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.OPENLIBRARY.value,
            media_type=MediaTypes.BOOK.value,
            media_id="progress-activity",
            title="Progress Activity",
        )
        change = ProgressChange.objects.create(
            actor=user,
            item=item,
            previous_progress={"kind": "percentage", "value": 42, "max": 100, "unit": "percent"},
            current_progress={"kind": "percentage", "value": 58, "max": 100, "unit": "percent"},
        )
        Activity.objects.create(
            actor=user,
            verb="progress_updated",
            target_type="progress_change",
            target_id=change.id,
            item=item,
            snapshot={
                "previous": change.previous_progress,
                "current": change.current_progress,
            },
        )
        Activity.objects.create(
            actor=user,
            verb="diary_updated",
            target_type="diary",
            target_id=1,
            item=item,
        )
        Activity.objects.create(
            actor=user,
            verb="list_item_added",
            target_type="list",
            target_id=1,
            item=item,
        )
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/users/progress-activity/activity/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data["results"]), 1)
        activity = response.data["results"][0]
        self.assertEqual(activity["type"], "progress_updated")
        self.assertEqual(activity["object"]["type"], "progress_change")
        self.assertEqual(activity["object"]["previous"]["value"], 42)
        self.assertEqual(activity["object"]["current"]["value"], 58)

    def test_user_activity_hides_deleted_diary_targets(self):
        user = get_user_model().objects.create_user(username="deleted-diary-activity", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="deleted-diary-activity",
            title="Deleted Diary Activity",
        )
        entry = DiaryEntry.objects.create(user=user, item=item, consumed_at=timezone.now())
        Activity.objects.create(
            actor=user,
            verb="diary_created",
            target_type="diary",
            target_id=entry.id,
            item=item,
        )
        entry.delete()
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/users/deleted-diary-activity/activity/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["results"], [])

    def test_set_media_like_is_idempotent_and_keeps_social_likes_separate(self):
        user = get_user_model().objects.create_user(username="media-like-service", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="svc",
            title="Service",
        )
        entry = DiaryEntry.objects.create(user=user, item=item, consumed_at=timezone.now(), liked=True)
        ContentLike.objects.create(user=user, target_type=ContentLike.DIARY_ENTRY, target_id=entry.id)

        set_media_like(user, item, liked=True)
        set_media_like(user, item, liked=True)
        set_media_like(user, item, liked=False)

        entry.refresh_from_db()
        self.assertEqual(MediaLike.objects.filter(user=user, item=item).count(), 0)
        self.assertFalse(entry.liked)
        self.assertEqual(ContentLike.objects.filter(user=user, target_type=ContentLike.DIARY_ENTRY).count(), 1)

    @patch("api.views.profile.provider_services.get_media_metadata")
    def test_liked_media_endpoint_materializes_without_tracking_or_diary(self, metadata_mock):
        user = get_user_model().objects.create_user(username="liked-media", password="strong-password-123")
        self.client.force_authenticate(user)
        metadata_mock.return_value = {"title": "Fight Club", "image": "https://example.com/fight.jpg"}
        payload = {
            "ref": {
                "source": Sources.TMDB.value,
                "media_type": MediaTypes.MOVIE.value,
                "media_id": "550",
            },
        }

        liked = self.client.post("/api/v1/me/liked-media/", payload, format="json")
        listed = self.client.get("/api/v1/me/liked-media/")
        unliked = self.client.delete("/api/v1/me/liked-media/", payload, format="json")

        item = Item.objects.get(media_id="550", media_type=MediaTypes.MOVIE.value)
        self.assertEqual(liked.status_code, status.HTTP_200_OK)
        self.assertTrue(liked.data["liked"])
        self.assertEqual(listed.status_code, status.HTTP_200_OK)
        self.assertEqual(listed.data["count"], 1)
        self.assertEqual(listed.data["results"][0]["title"], "Fight Club")
        self.assertEqual(unliked.status_code, status.HTTP_200_OK)
        self.assertFalse(unliked.data["liked"])
        self.assertFalse(MediaLike.objects.filter(user=user, item=item).exists())
        self.assertFalse(Movie.objects.filter(user=user, item=item).exists())
        self.assertFalse(DiaryEntry.objects.filter(user=user, item=item).exists())

    def test_liked_media_list_paginates_and_filters_media_type(self):
        user = get_user_model().objects.create_user(username="liked-pages", password="strong-password-123")
        movie_items = self._create_movie_items(30, title_prefix="Liked", media_id_prefix="liked")
        book = Item.objects.create(
            source=Sources.HARDCOVER.value,
            media_type=MediaTypes.BOOK.value,
            media_id="book-liked",
            title="Liked Book",
        )
        for item in [*movie_items, book]:
            MediaLike.objects.create(user=user, item=item)
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/me/liked-media/", {"media_type": MediaTypes.MOVIE.value})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 30)
        self.assertEqual(len(response.data["results"]), 25)
        self.assertIsNotNone(response.data["next"])

    @patch("api.services.diary.provider_services.get_media_metadata")
    def test_diary_liked_syncs_canonical_media_like(self, metadata_mock):
        user = get_user_model().objects.create_user(username="diary-media-like", password="strong-password-123")
        self.client.force_authenticate(user)
        metadata_mock.return_value = {"title": "Diary Like", "image": "https://example.com/diary.jpg"}
        payload = {
            "ref": {
                "source": Sources.TMDB.value,
                "media_type": MediaTypes.MOVIE.value,
                "media_id": "diary-like",
            },
            "liked": True,
        }

        created = self.client.post("/api/v1/diary/", payload, format="json")
        item = Item.objects.get(media_id="diary-like", media_type=MediaTypes.MOVIE.value)
        self.assertEqual(created.status_code, status.HTTP_201_CREATED)
        self.assertTrue(MediaLike.objects.filter(user=user, item=item).exists())
        activity_response = self.client.get("/api/v1/users/diary-media-like/activity/")
        self.assertEqual(activity_response.status_code, status.HTTP_200_OK)
        created_activity = activity_response.data["results"][0]
        self.assertEqual(created_activity["type"], "diary_created")
        self.assertIsNone(created_activity["object"]["rating"])
        self.assertTrue(created_activity["object"]["liked"])

        patched_without_like = self.client.patch(
            f"/api/v1/diary/{created.data['id']}/",
            {"review": "still liked"},
            format="json",
        )
        self.assertEqual(patched_without_like.status_code, status.HTTP_200_OK)
        self.assertTrue(MediaLike.objects.filter(user=user, item=item).exists())

        patched_unliked = self.client.patch(
            f"/api/v1/diary/{created.data['id']}/",
            {"liked": False},
            format="json",
        )
        self.assertEqual(patched_unliked.status_code, status.HTTP_200_OK)
        self.assertFalse(MediaLike.objects.filter(user=user, item=item).exists())

    def test_diary_patch_updates_writable_fields(self):
        user = get_user_model().objects.create_user(username="diary-patch", password="strong-password-123")
        item = self._create_movie_items(1, title_prefix="Patch", media_id_prefix="patch")[0]
        entry = DiaryEntry.objects.create(user=user, item=item, consumed_at=datetime(2025, 1, 1, tzinfo=UTC))
        self.client.force_authenticate(user)

        response = self.client.patch(
            f"/api/v1/diary/{entry.id}/",
            {
                "consumed_at": "2025-02-03T04:05:06Z",
                "rating": "8.5",
                "review_title": "Tighter",
                "review": "Still works.",
                "tags": ["theater", "rewatch night"],
                "visibility": "followers",
                "contains_spoilers": True,
                "is_rewatch": True,
                "liked": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["rating"], "8.5")
        self.assertEqual(response.data["review_title"], "Tighter")
        self.assertEqual(response.data["review"], "Still works.")
        self.assertCountEqual(response.data["tags"], ["theater", "rewatch night"])
        self.assertEqual(response.data["visibility"], "followers")
        self.assertTrue(response.data["contains_spoilers"])
        self.assertTrue(response.data["is_rewatch"])
        self.assertTrue(response.data["liked"])
        self.assertTrue(MediaLike.objects.filter(user=user, item=item).exists())

    @patch("app.models.providers.services.get_media_metadata", return_value={"max_progress": None})
    def test_diary_patch_consumed_at_updates_completed_movie_end_date(self, _metadata_mock):
        user = get_user_model().objects.create_user(username="diary-date-sync", password="strong-password-123")
        item = self._create_movie_items(1, title_prefix="Date Sync", media_id_prefix="date-sync")[0]
        Movie.objects.create(
            user=user,
            item=item,
            status=Status.COMPLETED.value,
            end_date=datetime(2025, 1, 1, tzinfo=UTC),
        )
        entry = DiaryEntry.objects.create(user=user, item=item, consumed_at=datetime(2025, 1, 1, tzinfo=UTC))
        self.client.force_authenticate(user)

        response = self.client.patch(
            f"/api/v1/diary/{entry.id}/",
            {"consumed_at": "2025-03-04T00:00:00Z"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(Movie.objects.get(user=user, item=item).end_date, datetime(2025, 3, 4, tzinfo=UTC))

    @patch("app.models.providers.services.get_media_metadata", return_value={"max_progress": None})
    def test_diary_delete_last_movie_entry_untracks(self, _metadata_mock):
        user = get_user_model().objects.create_user(username="diary-delete-last", password="strong-password-123")
        item = self._create_movie_items(1, title_prefix="Delete Last", media_id_prefix="delete-last")[0]
        Movie.objects.create(user=user, item=item, status=Status.COMPLETED.value)
        entry = DiaryEntry.objects.create(user=user, item=item, consumed_at=timezone.now())
        self.client.force_authenticate(user)

        response = self.client.delete(f"/api/v1/diary/{entry.id}/")

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(DiaryEntry.objects.filter(id=entry.id).exists())
        self.assertFalse(Movie.objects.filter(user=user, item=item).exists())

    @patch("app.models.providers.services.get_media_metadata", return_value={"max_progress": None})
    def test_diary_delete_with_remaining_entries_keeps_tracking(self, _metadata_mock):
        user = get_user_model().objects.create_user(username="diary-delete-remaining", password="strong-password-123")
        item = self._create_movie_items(1, title_prefix="Delete Keep", media_id_prefix="delete-keep")[0]
        Movie.objects.create(user=user, item=item, status=Status.COMPLETED.value)
        delete_entry = DiaryEntry.objects.create(user=user, item=item, consumed_at=datetime(2025, 1, 1, tzinfo=UTC))
        keep_entry = DiaryEntry.objects.create(user=user, item=item, consumed_at=datetime(2025, 1, 2, tzinfo=UTC))
        self.client.force_authenticate(user)

        response = self.client.delete(f"/api/v1/diary/{delete_entry.id}/")

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(DiaryEntry.objects.filter(id=delete_entry.id).exists())
        self.assertTrue(DiaryEntry.objects.filter(id=keep_entry.id).exists())
        self.assertTrue(Movie.objects.filter(user=user, item=item).exists())

    @patch("app.models.providers.services.get_media_metadata", return_value={"max_progress": None})
    @patch("api.services.diary.provider_services.get_media_metadata")
    def test_diary_create_anime_auto_mark_consumed(self, metadata_mock, _progress_mock):
        user = get_user_model().objects.create_user(username="diary-anime", password="strong-password-123")
        self.client.force_authenticate(user)
        metadata_mock.return_value = {"title": "Anime Log", "image": "https://example.com/anime.jpg"}

        response = self.client.post(
            "/api/v1/diary/",
            {
                "ref": {
                    "source": Sources.MAL.value,
                    "media_type": MediaTypes.ANIME.value,
                    "media_id": "anime-log",
                },
                "consumed_at": "2025-04-05T00:00:00Z",
                "auto_mark_consumed": True,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        item = Item.objects.get(media_id="anime-log", media_type=MediaTypes.ANIME.value)
        anime = Anime.objects.get(user=user, item=item)
        self.assertEqual(anime.status, Status.COMPLETED.value)
        self.assertEqual(anime.end_date, datetime(2025, 4, 5, tzinfo=UTC))

    def test_diary_update_emits_audit_not_recent_activity(self):
        user = get_user_model().objects.create_user(username="diary-social-log", password="strong-password-123")
        item = self._create_movie_items(1, title_prefix="Social Log", media_id_prefix="social-log")[0]
        entry = DiaryEntry.objects.create(user=user, item=item, consumed_at=datetime(2025, 1, 1, tzinfo=UTC))
        self.client.force_authenticate(user)

        patched = self.client.patch(f"/api/v1/diary/{entry.id}/", {"rating": "7.0"}, format="json")
        activity_response = self.client.get("/api/v1/users/diary-social-log/activity/")
        deleted = self.client.delete(f"/api/v1/diary/{entry.id}/")

        self.assertEqual(patched.status_code, status.HTTP_200_OK)
        self.assertEqual(activity_response.status_code, status.HTTP_200_OK)
        self.assertEqual(activity_response.data["results"], [])
        self.assertEqual(deleted.status_code, status.HTTP_204_NO_CONTENT)
        self.assertFalse(Activity.objects.filter(actor=user, target_type="diary", target_id=entry.id).exists())
        self.assertTrue(SocialAuditLog.objects.filter(actor=user, action="diary_updated", target_id=entry.id).exists())
        self.assertTrue(SocialAuditLog.objects.filter(actor=user, action="diary_deleted", target_id=entry.id).exists())

    @patch("app.providers.tmdb.get_title_logo", return_value=None)
    @patch("app.providers.tmdb.get_backdrop_images", return_value=[])
    @patch("app.providers.mdblist.get_media_ratings", return_value={})
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_media_detail_includes_canonical_like_state(self, metadata_mock, _ratings_mock, _backdrops_mock, _logo_mock):
        user = get_user_model().objects.create_user(username="liked-detail", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="detail-liked",
            title="Detail Like",
            image="https://example.com/detail.jpg",
        )
        MediaLike.objects.create(user=user, item=item)
        metadata_mock.return_value = {
            "media_id": "detail-liked",
            "media_type": MediaTypes.MOVIE.value,
            "source": Sources.TMDB.value,
            "title": "Detail Like",
            "image": "https://example.com/detail.jpg",
        }
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/media/tmdb/movie/detail-liked/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["user_state"]["has_liked"])
        self.assertEqual(response.data["community"]["liked_count"], 1)

    def _create_movies(self, user, count):
        items = self._create_movie_items(count)
        Movie.objects.bulk_create([Movie(user=user, item=item, status=Status.COMPLETED.value) for item in items])
        return items

    def _create_movie_items(self, count, title_prefix="Movie", media_id_prefix="m"):
        return [
            Item.objects.create(
                source=Sources.TMDB.value,
                media_type=MediaTypes.MOVIE.value,
                media_id=f"{media_id_prefix}{index}",
                title=f"{title_prefix} {index:02d}",
            )
            for index in range(count)
        ]

    @patch("api.views.profile.provider_services.get_media_metadata")
    def test_me_hof_put_materializes_missing_item(self, metadata_mock):
        user = get_user_model().objects.create_user(username="hof", password="strong-password-123")
        self.client.force_authenticate(user)
        metadata_mock.return_value = {
            "title": "Fight Club",
            "image": "https://example.com/fight-club.jpg",
        }

        response = self.client.put(
            "/api/v1/me/hof/movie/",
            {
                "ref": {
                    "item_id": None,
                    "source": Sources.TMDB.value,
                    "media_type": MediaTypes.MOVIE.value,
                    "media_id": "550",
                    "season_number": None,
                    "episode_number": None,
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        item = Item.objects.get(source=Sources.TMDB.value, media_type=MediaTypes.MOVIE.value, media_id="550")
        self.assertEqual(user.__class__.objects.get(id=user.id).hof_movie, item)
        self.assertEqual(set(response.data["items"]), {"tv", "movie", "anime", "manga", "game", "book", "comic"})
        self.assertEqual(response.data["items"]["movie"]["ref"]["item_id"], item.id)
        self.assertEqual(response.data["items"]["movie"]["ref"]["media_type"], "movie")
        self.assertEqual(response.data["items"]["movie"]["title"], "Fight Club")
        self.assertEqual(response.data["items"]["movie"]["image_url"], "https://example.com/fight-club.jpg")
        self.assertEqual(response.data["items"]["movie"]["poster_url"], "https://example.com/fight-club.jpg")

    def test_me_hof_put_updates_existing_slot(self):
        user = get_user_model().objects.create_user(username="hof2", password="strong-password-123")
        first = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Fight Club",
        )
        second = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="680",
            title="Pulp Fiction",
        )
        user.set_hall_of_fame_item(MediaTypes.MOVIE.value, first)
        user.save(update_fields=["hof_movie"])
        self.client.force_authenticate(user)

        response = self.client.put(
            "/api/v1/me/hof/movie/",
            {
                "ref": {
                    "item_id": second.id,
                    "source": Sources.TMDB.value,
                    "media_type": MediaTypes.MOVIE.value,
                    "media_id": "680",
                    "season_number": None,
                    "episode_number": None,
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        user.refresh_from_db()
        self.assertEqual(user.hof_movie, second)
        self.assertEqual(response.data["items"]["movie"]["title"], "Pulp Fiction")

    def test_me_hof_delete_clears_slot(self):
        user = get_user_model().objects.create_user(username="hof3", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.TV.value,
            media_id="1399",
            title="Game of Thrones",
        )
        user.set_hall_of_fame_item(MediaTypes.TV.value, item)
        user.save(update_fields=["hof_tv"])
        self.client.force_authenticate(user)

        response = self.client.delete("/api/v1/me/hof/tv/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        user.refresh_from_db()
        self.assertIsNone(user.hof_tv)
        self.assertIsNone(response.data["items"]["tv"])

    def test_me_hof_put_rejects_invalid_and_mismatched_media_type(self):
        user = get_user_model().objects.create_user(username="hof4", password="strong-password-123")
        self.client.force_authenticate(user)

        invalid = self.client.put(
            "/api/v1/me/hof/season/",
            {
                "ref": {
                    "source": Sources.TMDB.value,
                    "media_type": MediaTypes.SEASON.value,
                    "media_id": "1399",
                    "season_number": 1,
                },
            },
            format="json",
        )
        mismatch = self.client.put(
            "/api/v1/me/hof/movie/",
            {
                "ref": {
                    "source": Sources.TMDB.value,
                    "media_type": MediaTypes.TV.value,
                    "media_id": "1399",
                },
            },
            format="json",
        )

        self.assertEqual(invalid.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(mismatch.status_code, status.HTTP_400_BAD_REQUEST)

    def test_me_hof_write_requires_auth(self):
        response = self.client.put(
            "/api/v1/me/hof/movie/",
            {
                "ref": {
                    "source": Sources.TMDB.value,
                    "media_type": MediaTypes.MOVIE.value,
                    "media_id": "550",
                },
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    @patch("api.services.media.provider_services.search")
    def test_media_search_contract(self, search_mock):
        user = get_user_model().objects.create_user(
            username="searcher",
            password="strong-password-123",
        )
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Fight Club",
            image="https://example.com/fight-club.jpg",
        )
        CustomPosterPreference.objects.create(
            user=user,
            item=item,
            custom_image_url="https://example.com/custom-fight-club.jpg",
        )
        self.client.force_authenticate(user)
        search_mock.return_value = {
            "results": [
                {
                    "media_id": "550",
                    "title": "Fight Club",
                    "image": "https://example.com/fight-club.jpg",
                    "poster_width": 500,
                    "poster_height": 750,
                    "backdrop_path": "/fight-club-backdrop.jpg",
                    "release_date": "1999-10-15",
                    "ratings_count": 1000,
                    "total_rating_count": 1000,
                },
            ],
        }

        response = self.client.get("/api/v1/media/search/?media_type=movie&q=fight")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["results"][0]["ref"]["source"], "tmdb")
        self.assertEqual(response.data["results"][0]["ref"]["media_type"], "movie")
        self.assertEqual(response.data["results"][0]["title"], "Fight Club")
        self.assertEqual(response.data["results"][0]["image_url"], response.data["results"][0]["poster_url"])
        self.assertEqual(response.data["results"][0]["custom_poster_url"], "https://example.com/custom-fight-club.jpg")
        self.assertEqual(response.data["results"][0]["poster_orientation"], "portrait")
        self.assertEqual(response.data["results"][0]["poster_aspect_ratio"], 0.667)
        self.assertEqual(
            response.data["results"][0]["backdrop_url"],
            "https://image.tmdb.org/t/p/original/fight-club-backdrop.jpg",
        )
        self.assertNotIn("ratings_count", response.data["results"][0])
        self.assertNotIn("total_rating_count", response.data["results"][0])

    @patch("api.services.media.provider_services.discover")
    def test_media_discover_movie_genre_year_contract(self, discover_mock):
        user = get_user_model().objects.create_user(username="discoverer", password="strong-password-123")
        self.client.force_authenticate(user)
        discover_mock.return_value = {
            "per_page": 20,
            "total_results": 1,
            "results": [
                {
                    "media_id": "550",
                    "source": Sources.TMDB.value,
                    "media_type": MediaTypes.MOVIE.value,
                    "title": "Fight Club",
                    "image": "https://example.com/fight-club.jpg",
                    "release_date": "1999-10-15",
                    "vote_count": 1000,
                },
            ],
        }

        response = self.client.get("/api/v1/media/discover/?media_type=movie&genre=Drama&year=1999")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 1)
        self.assertIsNone(response.data["next"])
        self.assertEqual(response.data["results"][0]["ref"]["source"], Sources.TMDB.value)
        self.assertEqual(response.data["results"][0]["ref"]["media_type"], MediaTypes.MOVIE.value)
        self.assertEqual(response.data["results"][0]["title"], "Fight Club")
        discover_mock.assert_called_once_with(
            MediaTypes.MOVIE.value,
            source=Sources.TMDB.value,
            page=1,
            page_size=25,
            genre="Drama",
            year="1999",
            platform=None,
            sort="vote_count",
        )

    @patch("api.services.media.provider_services.discover")
    def test_media_discover_tv_uses_tmdb_summary_shape(self, discover_mock):
        user = get_user_model().objects.create_user(username="tv-discoverer", password="strong-password-123")
        self.client.force_authenticate(user)
        discover_mock.return_value = {
            "per_page": 20,
            "total_results": 1,
            "results": [
                {
                    "media_id": "1396",
                    "source": Sources.TMDB.value,
                    "media_type": MediaTypes.TV.value,
                    "title": "Breaking Bad",
                    "image": "https://example.com/breaking-bad.jpg",
                    "release_date": "2008-01-20",
                    "vote_count": 2000,
                },
            ],
        }

        response = self.client.get("/api/v1/media/discover/?media_type=tv&genre=Drama&year=2008")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["results"][0]["ref"]["media_type"], MediaTypes.TV.value)
        self.assertEqual(response.data["results"][0]["title"], "Breaking Bad")
        discover_mock.assert_called_once()

    @patch("api.services.media.provider_services.discover")
    def test_media_discover_game_platform_filter(self, discover_mock):
        user = get_user_model().objects.create_user(username="game-discoverer", password="strong-password-123")
        self.client.force_authenticate(user)
        discover_mock.return_value = {
            "per_page": 10,
            "total_results": 30,
            "results": [
                {
                    "media_id": "1020",
                    "source": Sources.IGDB.value,
                    "media_type": MediaTypes.GAME.value,
                    "title": "Elden Ring",
                    "image": "https://example.com/elden-ring.jpg",
                    "release_date": "2022-02-25",
                    "total_rating_count": 3000,
                },
            ],
        }

        response = self.client.get(
            "/api/v1/media/discover/?media_type=game&platform=PlayStation%205&page_size=10",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 30)
        self.assertIsNotNone(response.data["next"])
        self.assertEqual(response.data["results"][0]["ref"]["source"], Sources.IGDB.value)
        discover_mock.assert_called_once_with(
            MediaTypes.GAME.value,
            source=Sources.IGDB.value,
            page=1,
            page_size=10,
            genre=None,
            year=None,
            platform="PlayStation 5",
            sort="vote_count",
        )

    @patch("api.services.media.provider_services.discover")
    def test_media_discover_book_hardcover_genre_year_contract(self, discover_mock):
        user = get_user_model().objects.create_user(username="book-discoverer", password="strong-password-123")
        self.client.force_authenticate(user)
        discover_mock.return_value = {
            "per_page": 25,
            "total_results": 1,
            "results": [
                {
                    "media_id": "123",
                    "source": Sources.HARDCOVER.value,
                    "media_type": MediaTypes.BOOK.value,
                    "title": "The Hobbit",
                    "image": "https://example.com/hobbit.jpg",
                    "release_date": "1937",
                    "ratings_count": 5000,
                },
            ],
        }

        response = self.client.get("/api/v1/media/discover/?media_type=book&genre=Fantasy&year=1937")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["results"][0]["ref"]["source"], Sources.HARDCOVER.value)
        self.assertEqual(response.data["results"][0]["ref"]["media_type"], MediaTypes.BOOK.value)
        self.assertEqual(response.data["results"][0]["title"], "The Hobbit")
        discover_mock.assert_called_once_with(
            MediaTypes.BOOK.value,
            source=Sources.HARDCOVER.value,
            page=1,
            page_size=25,
            genre="Fantasy",
            year="1937",
            platform=None,
            sort="vote_count",
        )

    @patch("api.services.media.provider_services.discover")
    def test_media_discover_book_openlibrary_genre_and_year_contract(self, discover_mock):
        user = get_user_model().objects.create_user(username="ol-discoverer", password="strong-password-123")
        self.client.force_authenticate(user)
        discover_mock.return_value = {
            "per_page": 25,
            "total_results": 1,
            "results": [
                {
                    "media_id": "OL27448M",
                    "source": Sources.OPENLIBRARY.value,
                    "media_type": MediaTypes.BOOK.value,
                    "title": "Dune",
                    "image": "https://example.com/dune.jpg",
                    "release_date": "1965",
                    "ratings_count": 4000,
                },
            ],
        }

        genre = self.client.get("/api/v1/media/discover/?media_type=book&source=openlibrary&genre=Fiction")
        year = self.client.get("/api/v1/media/discover/?media_type=book&source=openlibrary&year=1965")

        self.assertEqual(genre.status_code, status.HTTP_200_OK)
        self.assertEqual(year.status_code, status.HTTP_200_OK)
        self.assertEqual(genre.data["results"][0]["ref"]["source"], Sources.OPENLIBRARY.value)
        self.assertEqual(year.data["results"][0]["title"], "Dune")
        self.assertEqual(discover_mock.call_count, 2)
        self.assertEqual(discover_mock.call_args_list[0].kwargs["genre"], "Fiction")
        self.assertIsNone(discover_mock.call_args_list[0].kwargs["year"])
        self.assertIsNone(discover_mock.call_args_list[1].kwargs["genre"])
        self.assertEqual(discover_mock.call_args_list[1].kwargs["year"], "1965")

    def test_media_discover_book_rejects_platform(self):
        user = get_user_model().objects.create_user(username="book-platform", password="strong-password-123")
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/media/discover/?media_type=book&platform=Kindle")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["detail"], "platform discovery is only supported for games.")

    def test_media_discover_book_unsupported_source_fails_clearly(self):
        user = get_user_model().objects.create_user(username="book-source", password="strong-password-123")
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/media/discover/?media_type=book&source=tmdb&genre=Fiction")

        self.assertEqual(response.status_code, status.HTTP_501_NOT_IMPLEMENTED)
        self.assertIn("Discovery is not supported", response.data["detail"])

    @patch("app.providers.tmdb.services.api_request")
    @patch("app.providers.tmdb._genre_map", return_value={"sci-fi-fantasy": 10765})
    def test_tmdb_tv_discover_resolves_fantasy_alias(self, _genre_map_mock, api_request_mock):
        from app.providers import tmdb

        api_request_mock.return_value = {
            "total_results": 1,
            "results": [
                {
                    "id": 1399,
                    "name": "Game of Thrones",
                    "poster_path": "/got.jpg",
                    "first_air_date": "2011-04-17",
                    "vote_count": 10000,
                },
            ],
        }

        response = tmdb.discover(MediaTypes.TV.value, genre="Fantasy")

        self.assertEqual(response["results"][0]["media_id"], 1399)
        self.assertEqual(api_request_mock.call_args.kwargs["params"]["with_genres"], 10765)

    @patch("app.providers.openlibrary.services.api_request")
    def test_openlibrary_discover_uses_subject_year_and_ratings_sort(self, api_request_mock):
        from app.providers import openlibrary

        api_request_mock.return_value = {
            "numFound": 1,
            "docs": [
                {
                    "title": "Dune",
                    "author_name": ["Frank Herbert"],
                    "edition_count": 10,
                    "first_publish_year": 1965,
                    "ratings_count": 4000,
                    "ratings_average": 4.2,
                    "editions": {
                        "docs": [
                            {
                                "key": "/books/OL27448M",
                                "title": "Dune",
                                "cover_i": 123,
                            },
                        ],
                    },
                },
            ],
        }

        response = openlibrary.discover(page=2, page_size=5, genre="Science Fiction", year="1965")

        params = api_request_mock.call_args.kwargs["params"]
        self.assertIn("subject_key:science_fiction", params["q"])
        self.assertIn('subject:"Science Fiction"', params["q"])
        self.assertIn("first_publish_year:1965", params["q"])
        self.assertEqual(params["sort"], "ratings_count desc")
        self.assertEqual(params["limit"], 5)
        self.assertEqual(response["results"][0]["media_id"], "OL27448M")

    @patch("app.providers.hardcover.services.api_request")
    def test_hardcover_discover_uses_genre_year_and_ratings_sort(self, api_request_mock):
        from app.providers import hardcover

        api_request_mock.return_value = {
            "data": {
                "books": [
                    {
                        "id": 123,
                        "title": "The Hobbit",
                        "cached_image": "https://example.com/hobbit.jpg",
                        "ratings_count": 5000,
                        "rating": 4.3,
                        "editions_count": 20,
                        "release_year": 1937,
                        "author_names": ["J. R. R. Tolkien"],
                    },
                ],
                "books_aggregate": {"aggregate": {"count": 1}},
            },
        }

        response = hardcover.discover(page=2, page_size=5, genre="Fantasy", year="1937")

        call = api_request_mock.call_args.kwargs["params"]
        self.assertIn("order_by: {ratings_count: desc}", call["query"])
        self.assertEqual(call["variables"]["limit"], 5)
        self.assertEqual(call["variables"]["offset"], 5)
        self.assertEqual(
            call["variables"]["where"],
            {
                "_and": [
                    {"cached_tags": {"_contains": {"Genre": [{"tag": "Fantasy"}]}}},
                    {"release_year": {"_eq": 1937}},
                ],
            },
        )
        self.assertEqual(response["results"][0]["media_id"], 123)

    @patch("app.providers.hardcover.services.api_request")
    def test_hardcover_person_page_returns_author_profile_and_books(self, api_request_mock):
        from app.providers import hardcover

        api_request_mock.side_effect = [
            {
                "data": {
                    "authors": [
                        {
                            "id": 80626,
                            "name": "Dan Wells",
                            "bio": "Author biography.",
                            "born_date": "1977-03-04",
                            "born_year": 1977,
                            "death_date": None,
                            "death_year": None,
                            "books_count": 12,
                            "cached_image": "https://example.com/dan.jpg",
                            "contributions": [],
                        },
                    ],
                },
            },
            {
                "data": {
                    "by_id": [
                        {
                            "id": 1,
                            "title": "Edited Anthology",
                            "cached_image": "https://example.com/anthology.jpg",
                            "release_year": 2010,
                            "release_date": "2010-03-30",
                            "rating": 4.8,
                            "ratings_count": 2000,
                            "reviews_count": 100,
                            "users_count": 9000,
                            "contributions": [
                                {
                                    "contribution": "Editor",
                                    "author": {"id": 80626, "name": "Dan Wells"},
                                },
                            ],
                        },
                    ],
                    "by_name": [
                        {
                            "id": 328491,
                            "title": "I Am Not a Serial Killer",
                            "cached_image": "https://example.com/book.jpg",
                            "release_year": 2009,
                            "release_date": "2009-03-30",
                            "rating": 3.8,
                            "ratings_count": 1000,
                            "reviews_count": 50,
                            "users_count": 2000,
                            "contributions": [
                                {
                                    "contribution": "Author",
                                    "author": {"id": 99, "name": "Dan Wells"},
                                },
                            ],
                        },
                        {
                            "id": 2,
                            "title": "Less Popular Authored Book",
                            "cached_image": "https://example.com/less.jpg",
                            "release_year": 2011,
                            "release_date": "2011-03-30",
                            "rating": 4.2,
                            "ratings_count": 500,
                            "reviews_count": 20,
                            "users_count": 100,
                            "contributions": [
                                {
                                    "contribution": "Author",
                                    "author": {"id": 80626, "name": "Dan Wells"},
                                },
                            ],
                        },
                    ],
                },
            },
        ]

        response = hardcover.person_page("80626")

        self.assertEqual(response["source"], Sources.HARDCOVER.value)
        self.assertEqual(response["person_id"], "80626")
        self.assertEqual(response["name"], "Dan Wells")
        self.assertEqual(response["image"], "https://example.com/dan.jpg")
        self.assertEqual(response["biography"], "Author biography.")
        self.assertEqual(response["known_for_department"], "Author")
        self.assertEqual(response["birth_date"], "1977-03-04")
        self.assertEqual(response["credits"][0]["media_type"], MediaTypes.BOOK.value)
        self.assertEqual(response["credits"][0]["media_id"], "328491")
        self.assertEqual(response["credits"][1]["media_id"], "2")
        self.assertEqual(response["credits"][2]["media_id"], "1")

    def test_hardcover_get_authors_returns_native_author_refs(self):
        from app.providers import hardcover

        authors = hardcover.get_authors({
            "cached_contributors": "Fallback Name",
            "contributions": [
                {"contribution": "Illustrator", "author": {"id": 1, "name": "Artist"}},
                {
                    "contribution": None,
                    "author": {"id": 80626, "name": "Dan Wells", "cached_image": "https://example.com/dan.jpg"},
                },
            ],
        })

        self.assertEqual(
            authors,
            [
                {
                    "name": "Dan Wells",
                    "person_id": "80626",
                    "source": Sources.HARDCOVER.value,
                    "image_url": "https://example.com/dan.jpg",
                },
            ],
        )

    def test_media_discover_validation_errors(self):
        user = get_user_model().objects.create_user(username="discover-errors", password="strong-password-123")
        self.client.force_authenticate(user)

        missing = self.client.get("/api/v1/media/discover/")
        invalid = self.client.get("/api/v1/media/discover/?media_type=movie&year=99&sort=recent&page=0")

        self.assertEqual(missing.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("media_type", missing.data)
        self.assertIn("non_field_errors", missing.data)
        self.assertEqual(invalid.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("year", invalid.data)
        self.assertIn("sort", invalid.data)
        self.assertIn("page", invalid.data)

    def test_media_discover_unsupported_media_type_fails_clearly(self):
        user = get_user_model().objects.create_user(username="unsupported-discover", password="strong-password-123")
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/media/discover/?media_type=anime&genre=Drama")

        self.assertEqual(response.status_code, status.HTTP_501_NOT_IMPLEMENTED)
        self.assertIn("Discovery is not supported", response.data["detail"])

    @patch("app.providers.tmdb.get_title_logo", return_value=None)
    @patch("app.providers.tmdb.get_backdrop_images", return_value=[])
    @patch("app.providers.mdblist.get_media_ratings")
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_media_detail_includes_synopsis_and_external_ratings(
        self,
        metadata_mock,
        ratings_mock,
        _backdrops_mock,
        _logo_mock,
    ):
        metadata_mock.return_value = {
            "media_id": "550",
            "media_type": "movie",
            "source": "tmdb",
            "source_url": "https://www.themoviedb.org/movie/550",
            "title": "Fight Club",
            "image": "https://example.com/fight-club.jpg",
            "backdrop_path": "/rr7E0NoGKxvbkb89eR1GwfoYjpA.jpg",
            "synopsis": "Soap, clubs, and insomnia.",
            "score": "8.4",
            "score_count": 1000,
            "genres": [{"name": "Drama"}, "Thriller"],
            "details": {
                "runtime": "2h 19m",
                "director": "David Fincher",
                "director_id": 7467,
                "directors": [
                    {"id": "7467", "name": "David Fincher"},
                    {"id": "9123", "name": "Jane Director"},
                ],
            },
            "cast": [{"person_id": 819, "name": "Edward Norton", "character": "Narrator", "image": "/ed.jpg"}],
            "crew": [{"person_id": 7467, "name": "David Fincher", "roles": ["Director"], "job": "Director", "image": "/fincher.jpg"}],
            "external_links": {
                "IMDb": "http://www.imdb.com/title/tt0137523/",
                "Letterboxd": "https://letterboxd.com/tmdb/550",
            },
            "related": {
                "Fight Club Collection": [
                    {
                        "media_id": "551",
                        "media_type": "movie",
                        "source": "tmdb",
                        "title": "Fight Club 2",
                        "image": "https://example.com/fight-club-2.jpg",
                    },
                ],
                "recommendations": [
                    {
                        "media_id": "680",
                        "media_type": "movie",
                        "source": "tmdb",
                        "title": "Pulp Fiction",
                        "image": "https://example.com/pulp.jpg",
                        "poster_width": 500,
                        "poster_height": 750,
                    },
                ],
                "seasons": [
                    {
                        "media_id": "550",
                        "media_type": "season",
                        "source": "tmdb",
                        "season_number": 1,
                        "title": "Season 1",
                    },
                ],
            },
        }
        ratings_mock.return_value = {
            "imdb": {"value": "8.8", "votes": 2300000},
            "letterboxd": {"value": "4.3", "votes": 500000},
            "tomatoes": {"value": "79%", "votes": 100, "url": "/m/fight_club"},
        }
        user = get_user_model().objects.create_user(username="viewer", password="strong-password-123")
        self.client.force_authenticate(user)
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Fight Club",
        )
        consumed_at = timezone.now()
        diary_entry = DiaryEntry.objects.create(
            user=user,
            item=item,
            consumed_at=consumed_at,
            rating="10.0",
            visibility="public",
        )

        response = self.client.get("/api/v1/media/tmdb/movie/550/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["overview"], "Soap, clubs, and insomnia.")
        self.assertEqual(response.data["synopsis"], "Soap, clubs, and insomnia.")
        self.assertEqual(
            response.data["backdrop_url"],
            "https://image.tmdb.org/t/p/original/rr7E0NoGKxvbkb89eR1GwfoYjpA.jpg",
        )
        self.assertIsNone(response.data["custom_backdrop_url"])
        self.assertEqual(
            [(rating["source"], rating["value"]) for rating in response.data["external_ratings"]],
            [("TMDB", "8.4"), ("IMDb", "8.8"), ("Letterboxd", "4.3"), ("Rotten Tomatoes", "79%")],
        )
        self.assertEqual(
            {rating["source"]: rating["url"] for rating in response.data["external_ratings"]},
            {
                "TMDB": "https://www.themoviedb.org/movie/550",
                "IMDb": "https://www.imdb.com/title/tt0137523/",
                "Letterboxd": "https://letterboxd.com/tmdb/550",
                "Rotten Tomatoes": "https://www.rottentomatoes.com/m/fight_club",
            },
        )
        self.assertEqual(response.data["details"]["genres"], ["Drama", "Thriller"])
        self.assertEqual(response.data["details"]["director"], "David Fincher")
        self.assertEqual(response.data["details"]["director_id"], 7467)
        self.assertEqual(
            response.data["details"]["directors"],
            [
                {"id": "7467", "name": "David Fincher"},
                {"id": "9123", "name": "Jane Director"},
            ],
        )
        self.assertEqual(response.data["cast"][0]["name"], "Edward Norton")
        self.assertEqual(response.data["crew"][0]["role"], "Director")
        self.assertEqual(response.data["crew"][0]["image_url"], "http://testserver/fincher.jpg")
        self.assertEqual(response.data["related_sections"][0]["id"], "collection")
        self.assertEqual(response.data["related_sections"][1]["items"][0]["title"], "Pulp Fiction")
        self.assertEqual(
            response.data["related_sections"][1]["items"][0]["image_url"],
            response.data["related_sections"][1]["items"][0]["poster_url"],
        )
        self.assertEqual(response.data["related_sections"][1]["items"][0]["poster_orientation"], "portrait")
        self.assertNotIn("seasons", [section["id"] for section in response.data["related_sections"]])
        self.assertEqual(response.data["user_state"]["diary_rating"], "10.0")
        self.assertEqual(response.data["user_state"]["diary_consumed_at"], consumed_at)
        self.assertEqual(response.data["user_state"]["diary_entry_id"], diary_entry.id)
        self.assertEqual(response.data["user_state"]["diary_count"], 1)
        item.refresh_from_db()
        self.assertEqual(str(item.imdb_rating), "8.80")
        self.assertEqual(str(item.letterboxd_rating), "4.30")
        self.assertEqual(str(item.rotten_tomatoes_rating), "79.00")
        self.assertTrue(ItemFilterFacet.objects.filter(item=item, facet_type="genre", value="Drama").exists())

    @patch("app.providers.mdblist.get_media_ratings")
    def test_external_rating_urls_only_use_verified_fallbacks(self, ratings_mock):
        ratings_mock.return_value = {
            "letterboxd": {"value": "4.3", "votes": 500000},
            "tomatoes": {"value": "79%", "votes": 100},
        }

        movie_ratings = external_ratings(
            metadata={},
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
        )
        tv_ratings = external_ratings(
            metadata={},
            source=Sources.TMDB.value,
            media_type=MediaTypes.TV.value,
            media_id="1399",
        )

        self.assertEqual(movie_ratings[0]["url"], "https://letterboxd.com/tmdb/550")
        self.assertIsNone(movie_ratings[1]["url"])
        self.assertIsNone(tv_ratings[0]["url"])
        self.assertIsNone(tv_ratings[1]["url"])

    @patch("app.providers.mdblist.get_media_ratings")
    def test_tv_and_season_rating_urls_use_available_series_pages(self, ratings_mock):
        ratings_mock.return_value = {
            "imdb": {"value": "9.2", "votes": 2500000},
            "letterboxd": {
                "value": "4.6",
                "votes": 900000,
                "url": "https://letterboxd.com/film/a-supported-limited-series/",
            },
            "tomatoes": {
                "value": "89%",
                "votes": 400,
                "url": "//www.rottentomatoes.com/tv/example_show",
            },
        }
        metadata = {
            "external_links": {"IMDb": "https://www.imdb.com/title/tt0944947/"},
        }
        expected_urls = {
            "IMDb": "https://www.imdb.com/title/tt0944947/",
            "Letterboxd": "https://letterboxd.com/film/a-supported-limited-series/",
            "Rotten Tomatoes": "https://www.rottentomatoes.com/tv/example_show",
        }

        for media_type, season_number in [
            (MediaTypes.TV.value, None),
            (MediaTypes.SEASON.value, 1),
        ]:
            ratings = external_ratings(
                metadata=metadata,
                source=Sources.TMDB.value,
                media_type=media_type,
                media_id="1399",
                season_number=season_number,
            )

            self.assertEqual(
                {rating["source"]: rating["url"] for rating in ratings},
                expected_urls,
            )

    @patch("api.services.media.provider_services.get_media_metadata")
    def test_landscape_only_artwork_marks_poster_orientation(self, metadata_mock):
        metadata_mock.return_value = {
            "media_id": "blue-lock-extra",
            "media_type": "anime",
            "source": "mal",
            "title": "Blue Lock Additional Time",
            "image": "https://example.com/banner.jpg",
            "poster_width": 1200,
            "poster_height": 675,
            "backdrop_url": "https://example.com/backdrop.jpg",
        }

        response = self.client.get("/api/v1/media/mal/anime/blue-lock-extra/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["image_url"], response.data["poster_url"])
        self.assertEqual(response.data["poster_orientation"], "landscape")
        self.assertEqual(response.data["poster_aspect_ratio"], 1.778)
        self.assertEqual(response.data["backdrop_url"], "https://example.com/backdrop.jpg")

    @patch("api.services.media.provider_services.get_person_page")
    def test_person_detail_returns_tmdb_profile_and_vote_count_sorted_filmography(self, person_mock):
        person_mock.return_value = {
            "source": Sources.TMDB.value,
            "person_id": "819",
            "name": "Edward Norton",
            "image": "https://image.tmdb.org/t/p/w500/profile.jpg",
            "biography": "An actor biography.",
            "known_for_department": "Acting",
            "birth_date": "1969-08-18",
            "death_date": None,
            "place_of_birth": "Boston, Massachusetts, USA",
            "popularity": 42.7,
            "credits": [
                {
                    "media_type": MediaTypes.MOVIE.value,
                    "source": Sources.TMDB.value,
                    "media_id": "550",
                    "title": "Fight Club",
                    "image": "https://example.com/fight-club.jpg",
                    "year": "1999",
                    "roles": ["Narrator"],
                    "credit_roles": ["Actor"],
                    "popularity": 20.5,
                    "vote_count": 2000,
                },
                {
                    "media_type": MediaTypes.TV.value,
                    "source": Sources.TMDB.value,
                    "media_id": "1399",
                    "title": "Game of Thrones",
                    "image": "https://example.com/got.jpg",
                    "year": "2011",
                    "roles": ["Director"],
                    "credit_roles": ["Director"],
                    "popularity": 80.2,
                    "vote_count": 100,
                },
            ],
        }

        response = self.client.get("/api/v1/people/tmdb/819/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        person_mock.assert_called_once_with(Sources.TMDB.value, "819")
        self.assertEqual(response.data["id"], "819")
        self.assertEqual(response.data["source"], Sources.TMDB.value)
        self.assertEqual(response.data["name"], "Edward Norton")
        self.assertEqual(response.data["profile_url"], "https://image.tmdb.org/t/p/w500/profile.jpg")
        self.assertEqual(response.data["known_for_department"], "Acting")
        self.assertEqual(response.data["birth_date"], "1969-08-18")
        self.assertEqual(response.data["place_of_birth"], "Boston, Massachusetts, USA")
        self.assertEqual([item["title"] for item in response.data["credits"]["cast"]], ["Fight Club", "Game of Thrones"])
        self.assertEqual(response.data["credits"]["cast"][0]["ref"]["media_type"], MediaTypes.MOVIE.value)
        self.assertEqual(response.data["credits"]["cast"][0]["subtitle"], "1999")
        self.assertEqual(response.data["credits"]["cast"][0]["poster_url"], "https://example.com/fight-club.jpg")
        self.assertEqual(response.data["credits"]["cast"][0]["roles"], ["Narrator"])
        self.assertEqual(response.data["credits"]["cast"][0]["credit_roles"], ["Actor"])

    @patch("api.services.media.provider_services.get_person_page")
    def test_person_detail_filters_and_sorts_credits_in_memory(self, person_mock):
        person_mock.return_value = {
            "source": Sources.TMDB.value,
            "person_id": "819",
            "name": "Edward Norton",
            "credits": [
                {
                    "media_type": MediaTypes.MOVIE.value,
                    "source": Sources.TMDB.value,
                    "media_id": "1",
                    "title": "Older Movie",
                    "year": "1999",
                    "vote_average": 9.0,
                },
                {
                    "media_type": MediaTypes.MOVIE.value,
                    "source": Sources.TMDB.value,
                    "media_id": "2",
                    "title": "Newer Movie",
                    "year": "2024",
                    "vote_average": 6.0,
                },
                {
                    "media_type": MediaTypes.TV.value,
                    "source": Sources.TMDB.value,
                    "media_id": "3",
                    "title": "TV Credit",
                    "year": "2025",
                    "vote_average": 10.0,
                },
            ],
        }

        response = self.client.get(
            "/api/v1/people/tmdb/819/",
            {
                "media_type": MediaTypes.MOVIE.value,
                "year_min": "2000",
                "sort": "release_date",
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [item["title"] for item in response.data["credits"]["cast"]],
            ["Newer Movie"],
        )

    @patch("app.providers.services.get_media_metadata")
    @patch("api.services.media.provider_services.get_person_page")
    def test_person_detail_filters_released_feature_films(self, person_mock, metadata_mock):
        Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="released-feature",
            title="Released Feature",
            runtime_minutes=90,
        )
        person_mock.return_value = {
            "source": Sources.TMDB.value,
            "person_id": "525",
            "name": "Director",
            "credits": [
                {
                    "media_type": MediaTypes.MOVIE.value,
                    "source": Sources.TMDB.value,
                    "media_id": "released-feature",
                    "title": "Released Feature",
                    "release_date": "2024-01-01",
                    "genres": ["Science Fiction"],
                    "languages": ["English"],
                    "vote_average": 8.0,
                },
                {
                    "media_type": MediaTypes.MOVIE.value,
                    "source": Sources.TMDB.value,
                    "media_id": "released-uncached-runtime",
                    "title": "Released Uncached Runtime",
                    "release_date": "2023-01-01",
                    "genres": ["Science Fiction"],
                    "languages": ["English"],
                    "vote_average": 7.0,
                },
                {
                    "media_type": MediaTypes.MOVIE.value,
                    "source": Sources.TMDB.value,
                    "media_id": "released-short",
                    "title": "Released Short",
                    "release_date": "2024-06-01",
                    "genres": ["Documentary"],
                    "languages": ["English"],
                    "runtime_minutes": 12,
                    "vote_average": 9.0,
                },
                {
                    "media_type": MediaTypes.MOVIE.value,
                    "source": Sources.TMDB.value,
                    "media_id": "future-feature",
                    "title": "Future Feature",
                    "release_date": "2099-01-01",
                    "genres": ["Science Fiction"],
                    "languages": ["English"],
                    "runtime_minutes": 90,
                    "vote_average": 10.0,
                },
            ],
        }

        response = self.client.get(
            "/api/v1/people/tmdb/525/",
            {
                "media_type": MediaTypes.MOVIE.value,
                "release_status": "released",
                "length": "feature",
                "genre": "Science Fiction",
                "language": "English",
                "sort": "release_date",
                "direction": "desc",
            },
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [item["title"] for item in response.data["credits"]["cast"]],
            ["Released Feature", "Released Uncached Runtime"],
        )
        self.assertEqual(response.data["credits"]["cast"][0]["genres"], ["Science Fiction"])
        self.assertEqual(response.data["credits"]["cast"][0]["languages"], ["English"])
        metadata_mock.assert_not_called()

    @patch("api.services.media.provider_services.get_person_page")
    def test_person_detail_returns_hardcover_author_books(self, person_mock):
        person_mock.return_value = {
            "source": Sources.HARDCOVER.value,
            "person_id": "80626",
            "name": "Dan Wells",
            "image": "https://example.com/dan.jpg",
            "biography": "Author biography.",
            "known_for_department": "Author",
            "birth_date": "1977-03-04",
            "death_date": None,
            "place_of_birth": None,
            "popularity": 12,
            "credits": [
                {
                    "media_type": MediaTypes.BOOK.value,
                    "source": Sources.HARDCOVER.value,
                    "media_id": "328491",
                    "title": "I Am Not a Serial Killer",
                    "image": "https://example.com/book.jpg",
                    "year": "2009",
                    "vote_count": 1000,
                },
            ],
        }

        response = self.client.get("/api/v1/people/hardcover/80626/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        person_mock.assert_called_once_with(Sources.HARDCOVER.value, "80626")
        self.assertEqual(response.data["source"], Sources.HARDCOVER.value)
        self.assertEqual(response.data["known_for_department"], "Author")
        self.assertEqual(response.data["credits"]["cast"][0]["ref"]["media_type"], MediaTypes.BOOK.value)
        self.assertEqual(response.data["credits"]["cast"][0]["ref"]["source"], Sources.HARDCOVER.value)
        self.assertEqual(response.data["credits"]["cast"][0]["title"], "I Am Not a Serial Killer")

    def test_person_detail_rejects_unsupported_source_for_v1(self):
        response = self.client.get("/api/v1/people/manual/author-1/")

        self.assertEqual(response.status_code, status.HTTP_501_NOT_IMPLEMENTED)
        self.assertEqual(
            response.data["detail"],
            "People pages are only supported for TMDB, Hardcover, and OpenLibrary in v1.",
        )

    @patch("api.services.media.provider_services.company_catalog_count")
    @patch("api.services.media.provider_services.get_company")
    def test_company_detail_returns_igdb_studio_profile(self, company_mock, count_mock):
        company_mock.return_value = {
            "id": 77,
            "name": "Space Studio",
            "description": "Makes space games.",
            "logo": {
                "image_id": "studio-logo",
                "url": "//images.igdb.com/igdb/image/upload/t_thumb/studio-logo.jpg",
                "width": 284,
                "height": 160,
            },
            "country": 840,
            "start_date": int(datetime(1993, 1, 1, tzinfo=UTC).timestamp()),
            "status": {"name": "Active"},
            "company_size": {"name": "Medium"},
            "parent": {"id": 7, "name": "Parent Co"},
            "url": "https://www.igdb.com/companies/space-studio",
            "websites": [{"url": "https://example.com"}],
        }
        count_mock.side_effect = [24, 8]

        response = self.client.get("/api/v1/companies/igdb/77/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["id"], "77")
        self.assertEqual(response.data["logo_width"], 284)
        self.assertEqual(
            response.data["logo_url"],
            "https://images.igdb.com/igdb/image/upload/t_logo_med/studio-logo.png",
        )
        self.assertEqual(response.data["founded_year"], 1993)
        self.assertEqual(response.data["catalogs"], {"developed": {"count": 24}, "published": {"count": 8}})

    @patch("api.services.media.provider_services.get_company_catalog")
    def test_company_games_are_role_scoped_sorted_and_paginated(self, catalog_mock):
        catalog_mock.return_value = [
            {
                "media_id": 1,
                "title": "Older Game",
                "image": "https://example.com/older.jpg",
                "release_date": "2020-01-01",
                "vote_average": 9.0,
                "roles": ["Developer"],
                "credit_roles": ["Developer"],
            },
            {
                "media_id": 2,
                "title": "Newer Game",
                "image": "https://example.com/newer.jpg",
                "release_date": "2024-01-01",
                "vote_average": 7.0,
                "roles": ["Developer"],
                "credit_roles": ["Developer"],
            },
        ]

        response = self.client.get("/api/v1/companies/igdb/77/games/?role=developed&page_size=1")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 2)
        self.assertEqual(response.data["results"][0]["title"], "Newer Game")
        self.assertEqual(response.data["results"][0]["ref"]["source"], Sources.IGDB.value)
        catalog_mock.assert_called_once_with(Sources.IGDB.value, "77", "developed")

    def test_company_games_reject_invalid_role(self):
        response = self.client.get("/api/v1/companies/igdb/77/games/?role=credited")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["detail"], "role must be developed or published.")

    @patch("app.providers.tmdb.get_title_logo", return_value=None)
    @patch("app.providers.tmdb.get_backdrop_images", return_value=[])
    @patch("app.providers.mdblist.get_media_ratings", return_value={})
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_tv_detail_exposes_seasons(self, metadata_mock, _ratings_mock, _backdrops_mock, _logo_mock):
        metadata_mock.return_value = {
            "media_id": "1399",
            "media_type": "tv",
            "source": "tmdb",
            "title": "Game of Thrones",
            "image": "https://example.com/got.jpg",
            "backdrop_path": "/9xxLWtnFxkpJ2h1uthpvCRK6vta.jpg",
            "related": {
                "seasons": [
                    {
                        "media_id": "1399",
                        "media_type": "season",
                        "source": "tmdb",
                        "season_number": 1,
                        "season_title": "Season 1",
                        "max_progress": 10,
                        "image": "https://example.com/s1.jpg",
                        "first_air_date": "2011-04-17",
                    },
                ],
            },
        }

        detail = self.client.get("/api/v1/media/tmdb/tv/1399/")
        seasons = self.client.get("/api/v1/media/tmdb/tv/1399/seasons/")

        self.assertEqual(detail.status_code, status.HTTP_200_OK)
        self.assertEqual(detail.data["seasons"][0]["title"], "Season 1")
        self.assertEqual(
            detail.data["backdrop_url"],
            "https://image.tmdb.org/t/p/original/9xxLWtnFxkpJ2h1uthpvCRK6vta.jpg",
        )
        self.assertEqual(seasons.data["seasons"], detail.data["seasons"])

    @patch("app.providers.tmdb.get_title_logo", return_value=None)
    @patch("app.providers.tmdb.get_season_backdrop_images")
    @patch("app.providers.mdblist.get_media_ratings", return_value={})
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_season_detail_uses_first_episode_still_as_default_backdrop(
        self,
        metadata_mock,
        _ratings_mock,
        season_backdrops_mock,
        _logo_mock,
    ):
        metadata_mock.return_value = {
            "media_id": "1399",
            "media_type": "season",
            "source": "tmdb",
            "title": "Game of Thrones",
            "season_title": "Season 1",
            "image": "https://example.com/season-poster.jpg",
            "season_number": 1,
            "episodes": [],
        }
        season_backdrops_mock.return_value = [
            {"url": "https://example.com/episode-1.jpg"},
            {"url": "https://example.com/episode-2.jpg"},
        ]

        response = self.client.get("/api/v1/media/tmdb/tv/1399/seasons/1/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["backdrop_url"], "https://example.com/episode-1.jpg")
        self.assertIsNone(response.data["custom_backdrop_url"])
        season_backdrops_mock.assert_called_once_with("1399", 1)

    @patch("app.providers.tmdb.get_title_logo", return_value=None)
    @patch("app.providers.tmdb.get_backdrop_images", return_value=[])
    @patch("app.providers.mdblist.get_media_ratings", return_value={})
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_media_detail_backdrop_url_is_null_without_backdrop(
        self,
        metadata_mock,
        _ratings_mock,
        _backdrops_mock,
        _logo_mock,
    ):
        metadata_mock.return_value = {
            "media_id": "550",
            "media_type": "movie",
            "source": "tmdb",
            "title": "Fight Club",
            "image": "https://example.com/fight-club.jpg",
        }

        response = self.client.get("/api/v1/media/tmdb/movie/550/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIsNone(response.data["backdrop_url"])
        self.assertIsNone(response.data["custom_backdrop_url"])

    @patch(
        "app.providers.tmdb.get_title_logo",
        return_value={
            "url": "https://image.tmdb.org/t/p/w500/logo.png",
            "width": 1493,
            "height": 482,
            "aspect_ratio": 3.1,
        },
    )
    @patch("app.providers.tmdb.get_backdrop_images", return_value=[])
    @patch("app.providers.mdblist.get_media_ratings", return_value={})
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_media_detail_includes_tmdb_logo_fields(self, metadata_mock, _ratings_mock, _backdrops_mock, logo_mock):
        metadata_mock.return_value = {
            "media_id": "550",
            "media_type": "movie",
            "source": "tmdb",
            "title": "Fight Club",
            "image": "https://example.com/fight-club.jpg",
        }

        response = self.client.get("/api/v1/media/tmdb/movie/550/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["logo_url"], "https://image.tmdb.org/t/p/w500/logo.png")
        self.assertEqual(response.data["logo_width"], 1493)
        self.assertEqual(response.data["logo_height"], 482)
        self.assertEqual(response.data["logo_aspect_ratio"], 3.1)
        logo_mock.assert_called_once_with("550", "movie")

    @patch("app.providers.tmdb.get_title_logo")
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_media_detail_logo_fields_are_null_when_unsupported(self, metadata_mock, logo_mock):
        metadata_mock.return_value = {
            "media_id": "1",
            "media_type": "anime",
            "source": "mal",
            "title": "Cowboy Bebop",
            "image": "https://example.com/bebop.jpg",
        }

        response = self.client.get("/api/v1/media/mal/anime/1/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIsNone(response.data["logo_url"])
        self.assertIsNone(response.data["logo_width"])
        logo_mock.assert_not_called()

    @patch("app.providers.mdblist.get_media_ratings", return_value={})
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_season_detail_exposes_episodes_with_runtime_string(self, metadata_mock, _ratings_mock):
        metadata_mock.return_value = {
            "media_id": "1399",
            "media_type": "season",
            "source": "tmdb",
            "title": "Game of Thrones",
            "season_number": 1,
            "image": "https://example.com/s1.jpg",
            "episodes": [
                {
                    "episode_number": 1,
                    "name": "Winter Is Coming",
                    "overview": "The beginning.",
                    "air_date": "2011-04-17",
                    "runtime": 62,
                    "still_path": "/ep1.jpg",
                    "vote_average": 8.2,
                },
            ],
        }

        detail = self.client.get("/api/v1/media/tmdb/season/1399/?season_number=1")
        episodes = self.client.get("/api/v1/media/tmdb/tv/1399/seasons/1/episodes/")

        self.assertEqual(detail.status_code, status.HTTP_200_OK)
        self.assertEqual(detail.data["episodes"][0]["runtime"], "1h 2m")
        self.assertEqual(detail.data["episodes"][0]["image_role"], "still")
        self.assertEqual(episodes.data["episodes"], detail.data["episodes"])

    @patch("api.services.media.provider_services.get_media_metadata")
    def test_mal_anime_detail_exposes_genres_related_and_rating(self, metadata_mock):
        metadata_mock.return_value = {
            "media_id": "1",
            "media_type": "anime",
            "source": "mal",
            "title": "Cowboy Bebop",
            "image": "https://example.com/bebop.jpg",
            "genres": ["Action", {"name": "Sci-Fi"}],
            "score": "8.75",
            "score_count": 100,
            "related": {
                "related_anime": [
                    {"media_id": "5", "media_type": "anime", "source": "mal", "title": "Movie"},
                ],
                "recommendations": [
                    {"media_id": "6", "media_type": "anime", "source": "mal", "title": "Champloo"},
                ],
            },
        }

        response = self.client.get("/api/v1/media/mal/anime/1/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["details"]["genres"], ["Action", "Sci-Fi"])
        self.assertEqual([section["id"] for section in response.data["related_sections"]], ["related_anime", "recommendations"])
        self.assertEqual(response.data["external_ratings"][0]["source"], "MAL")
        self.assertEqual(response.data["external_ratings"][0]["url"], "https://myanimelist.net/anime/1")

    def test_mal_manga_rating_uses_verified_id_url(self):
        ratings = external_ratings(
            metadata={"score": 9.4, "score_count": 750000},
            source=Sources.MAL.value,
            media_type=MediaTypes.MANGA.value,
            media_id="2",
        )

        self.assertEqual(ratings[0]["url"], "https://myanimelist.net/manga/2")

    @patch("api.services.media.provider_services.get_media_metadata")
    def test_mangaupdates_rating_uses_provider_source_url(self, metadata_mock):
        metadata_mock.return_value = {
            "media_id": "abc123",
            "media_type": "manga",
            "source": "mangaupdates",
            "source_url": "https://www.mangaupdates.com/series/abc123/example-manga",
            "title": "Example Manga",
            "score": "8.2",
            "score_count": 321,
        }

        response = self.client.get("/api/v1/media/mangaupdates/manga/abc123/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["external_ratings"][0]["source"], "MangaUpdates")
        self.assertEqual(
            response.data["external_ratings"][0]["url"],
            "https://www.mangaupdates.com/series/abc123/example-manga",
        )

    def test_mangaupdates_rating_without_source_url_stays_unlinked(self):
        for source_url in [None, "https://["]:
            ratings = external_ratings(
                metadata={"score": 8.2, "score_count": 321, "source_url": source_url},
                source=Sources.MANGAUPDATES.value,
                media_type=MediaTypes.MANGA.value,
                media_id="abc123",
            )

            self.assertIsNone(ratings[0]["url"])

    @patch("api.services.media.provider_services.get_media_metadata")
    def test_openlibrary_book_detail_exposes_other_editions(self, metadata_mock):
        metadata_mock.return_value = {
            "media_id": "OL1M",
            "media_type": "book",
            "source": "openlibrary",
            "title": "A Book",
            "image": "https://example.com/book.jpg",
            "score": "4.1",
            "related": {
                "other_editions": [
                    {"media_id": "OL2M", "media_type": "book", "source": "openlibrary", "title": "Paperback"},
                ],
            },
        }

        response = self.client.get("/api/v1/media/openlibrary/book/OL1M/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["related_sections"][0]["id"], "other_editions")
        self.assertEqual(response.data["external_ratings"][0]["max_value"], "5")
        self.assertEqual(response.data["external_ratings"][0]["value"], "4.1")
        self.assertEqual(response.data["external_ratings"][0]["url"], "https://openlibrary.org/books/OL1M")

    @patch("api.services.media.provider_services.get_media_metadata")
    def test_hardcover_book_detail_exposes_series_before_recommendations(self, metadata_mock):
        metadata_mock.return_value = {
            "media_id": "377193",
            "media_type": "book",
            "source": "hardcover",
            "title": "Harry Potter and the Sorcerer's Stone",
            "image": "https://example.com/hp1.jpg",
            "related": {
                "Harry Potter": [
                    {
                        "media_id": "377193",
                        "source": "hardcover",
                        "media_type": "book",
                        "title": "Harry Potter and the Sorcerer's Stone",
                        "image": "https://example.com/hp1.jpg",
                    },
                    {
                        "media_id": "377194",
                        "source": "hardcover",
                        "media_type": "book",
                        "title": "Harry Potter and the Chamber of Secrets",
                        "image": "https://example.com/hp2.jpg",
                    },
                ],
                "recommendations": [
                    {
                        "media_id": "1",
                        "source": "hardcover",
                        "media_type": "book",
                        "title": "A Recommendation",
                        "image": "https://example.com/rec.jpg",
                    },
                ],
            },
        }

        response = self.client.get("/api/v1/media/hardcover/book/377193/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["related_sections"][0]["id"], "series")
        self.assertEqual(response.data["related_sections"][0]["title"], "Harry Potter")
        self.assertEqual(response.data["related_sections"][0]["items"][1]["ref"]["media_id"], "377194")
        self.assertEqual(response.data["related_sections"][0]["items"][1]["title"], "Harry Potter and the Chamber of Secrets")
        self.assertEqual([section["id"] for section in response.data["related_sections"]], ["series", "recommendations"])

    @patch("api.services.media.provider_services.get_media_metadata")
    def test_hardcover_book_detail_omits_empty_series_section(self, metadata_mock):
        metadata_mock.return_value = {
            "media_id": "377193",
            "media_type": "book",
            "source": "hardcover",
            "title": "Standalone Book",
            "image": "https://example.com/book.jpg",
            "related": {
                "recommendations": [
                    {
                        "media_id": "1",
                        "source": "hardcover",
                        "media_type": "book",
                        "title": "A Recommendation",
                    },
                ],
            },
        }

        response = self.client.get("/api/v1/media/hardcover/book/377193/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual([section["id"] for section in response.data["related_sections"]], ["recommendations"])

    @patch("api.services.media.provider_services.get_media_metadata")
    def test_hardcover_book_external_rating_uses_native_five_point_scale(self, metadata_mock):
        metadata_mock.return_value = {
            "media_id": "377193",
            "media_type": "book",
            "source": "hardcover",
            "source_url": "https://hardcover.app/books/the-great-gatsby",
            "title": "The Great Gatsby",
            "image": "https://example.com/gatsby.jpg",
            "score": 4.3,
            "score_count": 1234,
        }

        response = self.client.get("/api/v1/media/hardcover/book/377193/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        rating = response.data["external_ratings"][0]
        self.assertEqual(rating["source"], "Hardcover")
        self.assertEqual(rating["value"], "4.3")
        self.assertEqual(rating["max_value"], "5")
        self.assertEqual(rating["vote_count"], 1234)
        self.assertEqual(rating["url"], "https://hardcover.app/books/the-great-gatsby")

    def test_hardcover_rating_without_slug_uses_id_redirect_url(self):
        ratings = external_ratings(
            metadata={"score": 4.3, "score_count": 1234},
            source=Sources.HARDCOVER.value,
            media_type=MediaTypes.BOOK.value,
            media_id="377193",
        )

        self.assertEqual(ratings[0]["url"], "https://hardcover.app/book/377193")

    @patch("app.providers.steam.get_metacritic_rating")
    @patch("app.providers.steamgriddb.get_game_logo", return_value=None)
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_game_detail_exposes_collection_before_other_related_sections(
        self,
        metadata_mock,
        _logo_mock,
        metacritic_mock,
    ):
        metacritic_mock.return_value = {
            "value": 94,
            "url": "https://www.metacritic.com/game/pc/space-game",
        }
        metadata_mock.return_value = {
            "media_id": "1020",
            "media_type": "game",
            "source": "igdb",
            "source_url": "https://www.igdb.com/games/space-game",
            "title": "Space Game",
            "image": "https://example.com/space.jpg",
            "artworks": [{"image_id": "wide-art"}],
            "score": "92.7",
            "score_count": 5000,
            "details": {
                "release_date": "2020-09-17",
                "age_rating": "ESRB M",
                "age_ratings": ["ESRB M", "PEGI 18"],
                "franchise": "Space Franchise",
                "franchises": ["Space Franchise"],
                "collection": "Space Collection",
            },
            "related": {
                "collection": [
                    {
                        "media_id": "1020",
                        "media_type": "game",
                        "source": "igdb",
                        "title": "Space Game",
                        "image": "https://example.com/space.jpg",
                    },
                    {
                        "media_id": "1021",
                        "media_type": "game",
                        "source": "igdb",
                        "title": "Space Game 2",
                        "image": "https://example.com/space2.jpg",
                    },
                ],
                "dlcs": [
                    {
                        "media_id": "1022",
                        "media_type": "game",
                        "source": "igdb",
                        "title": "Space Game DLC",
                    },
                ],
                "all_related": [
                    {
                        "media_id": "9999",
                        "media_type": "game",
                        "source": "igdb",
                        "title": "Random Related Game",
                    },
                ],
            },
        }

        response = self.client.get("/api/v1/media/igdb/game/1020/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual([section["id"] for section in response.data["related_sections"]], ["collection", "dlcs"])
        self.assertEqual(response.data["related_sections"][0]["items"][1]["title"], "Space Game 2")
        self.assertEqual(response.data["external_ratings"][0]["source"], "IGDB")
        self.assertEqual(response.data["external_ratings"][0]["value"], "92.7")
        self.assertEqual(response.data["external_ratings"][0]["max_value"], "100")
        self.assertEqual(response.data["external_ratings"][0]["vote_count"], 5000)
        self.assertEqual(response.data["external_ratings"][0]["url"], "https://www.igdb.com/games/space-game")
        self.assertEqual(response.data["external_ratings"][1]["source"], "Metacritic")
        self.assertEqual(response.data["external_ratings"][1]["value"], "94")
        self.assertEqual(response.data["external_ratings"][1]["max_value"], "100")
        self.assertEqual(response.data["external_ratings"][1]["url"], "https://www.metacritic.com/game/pc/space-game")
        self.assertEqual(response.data["release_date"], "2020-09-17")
        self.assertEqual(response.data["details"]["age_rating"], "ESRB M")
        self.assertEqual(response.data["details"]["age_ratings"], ["ESRB M", "PEGI 18"])
        self.assertEqual(response.data["details"]["franchise"], "Space Franchise")
        self.assertEqual(response.data["details"]["franchises"], ["Space Franchise"])
        self.assertEqual(response.data["details"]["collection"], "Space Collection")
        self.assertEqual(
            response.data["backdrop_url"],
            "https://images.igdb.com/igdb/image/upload/t_original/wide-art.jpg",
        )

    @patch("app.providers.steam.get_metacritic_rating", return_value=None)
    @patch("app.providers.steamgriddb.get_game_logo", return_value=None)
    @patch("app.providers.steamgriddb.get_game_backdrops", return_value=[])
    @patch(
        "app.providers.igdb.get_game_backdrops",
        return_value=[
            {
                "url": "https://example.com/game-backdrop.jpg",
                "thumbnail_url": "https://example.com/game-backdrop-thumb.jpg",
                "width": 1920,
                "height": 1080,
                "aspect_ratio": 1.778,
                "language": None,
            },
        ],
    )
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_game_detail_uses_available_backdrop_when_metadata_has_none(
        self,
        metadata_mock,
        _igdb_backdrops_mock,
        _steamgriddb_backdrops_mock,
        _logo_mock,
        _metacritic_mock,
    ):
        metadata_mock.return_value = {
            "media_id": "1020",
            "media_type": "game",
            "source": "igdb",
            "title": "Space Game",
            "image": "https://example.com/space.jpg",
            "details": {},
            "related": {},
        }

        response = self.client.get("/api/v1/media/igdb/game/1020/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["backdrop_url"], "https://example.com/game-backdrop.jpg")

    def test_community_stats_include_truthful_rating_distribution(self):
        user = get_user_model().objects.create_user(username="rater", password="strong-password-123")
        other = get_user_model().objects.create_user(username="other", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Fight Club",
            image="https://example.com/fight-club.jpg",
        )
        now = timezone.now()
        DiaryEntry.objects.create(user=user, item=item, consumed_at=now, rating="8.0", visibility="public")
        DiaryEntry.objects.create(user=other, item=item, consumed_at=now, rating="8.0", visibility="followers")
        DiaryEntry.objects.create(user=other, item=item, consumed_at=now, rating="9.0", visibility="private")
        DiaryEntry.objects.create(user=other, item=item, consumed_at=now, rating=None, visibility="public")

        response = self.client.get("/api/v1/media/tmdb/movie/550/community/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["average_rating"], "8.00")
        self.assertEqual(response.data["rating_count"], 2)
        self.assertEqual(response.data["rating_distribution"], [{"rating": "8.0", "count": 2}])

    def test_media_reviews_endpoint_returns_public_review_cards(self):
        user = get_user_model().objects.create_user(username="reviewer", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Fight Club",
            image="https://example.com/fight-club.jpg",
        )
        DiaryEntry.objects.create(
            user=user,
            item=item,
            consumed_at=timezone.now(),
            rating="9.0",
            review="Sharp and strange.",
            review_title="Mayhem",
            visibility="public",
        )
        DiaryEntry.objects.create(
            user=user,
            item=item,
            consumed_at=timezone.now(),
            review="Hidden.",
            visibility="private",
        )

        response = self.client.get("/api/v1/media/tmdb/movie/550/reviews/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 1)
        self.assertEqual(response.data["results"][0]["review"], "Sharp and strange.")

    def test_diary_media_embed_includes_artwork_fields(self):
        user = get_user_model().objects.create_user(username="diary-art", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.OPENLIBRARY.value,
            media_type=MediaTypes.BOOK.value,
            media_id="OL1M",
            title="A Book",
            image="https://example.com/book.jpg",
        )
        DiaryEntry.objects.create(user=user, item=item, consumed_at=timezone.now(), visibility="public")
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/diary/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        media = response.data["results"][0]["media"]
        self.assertEqual(media["image_url"], media["poster_url"])
        self.assertIsNone(media["backdrop_url"])
        self.assertEqual(media["poster_orientation"], "unknown")

    def test_diary_list_orders_by_consumed_at_not_import_creation_time(self):
        user = get_user_model().objects.create_user(username="diary-order", password="strong-password-123")
        recent_item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="recent",
            title="Recent",
        )
        old_item = Item.objects.create(
            source=Sources.HARDCOVER.value,
            media_type=MediaTypes.BOOK.value,
            media_id="old",
            title="Old Import",
        )
        recent = DiaryEntry.objects.create(user=user, item=recent_item, consumed_at=datetime(2026, 6, 1, tzinfo=UTC))
        old_import = DiaryEntry.objects.create(user=user, item=old_item, consumed_at=datetime(2024, 1, 7, tzinfo=UTC))
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/diary/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual([entry["id"] for entry in response.data["results"]], [recent.id, old_import.id])

    def test_diary_list_filters_by_multi_word_tag(self):
        user = get_user_model().objects.create_user(username="diary-tag", password="strong-password-123")
        theater_item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Theater Movie",
        )
        home_item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="551",
            title="Home Movie",
        )
        theater_entry = DiaryEntry.objects.create(user=user, item=theater_item, consumed_at=timezone.now())
        home_entry = DiaryEntry.objects.create(user=user, item=home_item, consumed_at=timezone.now())
        update_diary_entry_tags(theater_entry, ["in theater"])
        update_diary_entry_tags(home_entry, ["at home"])
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/diary/", {"tag": "in theater"})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 1)
        self.assertEqual(response.data["results"][0]["id"], theater_entry.id)
        self.assertEqual(response.data["results"][0]["tags"], ["in theater"])

    def test_diary_profile_menu_filters_reviews_likes_and_my_tags(self):
        user = get_user_model().objects.create_user(username="profile-menu", password="strong-password-123")
        other = get_user_model().objects.create_user(username="other-tags", password="strong-password-123")
        reviewed_item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Reviewed",
        )
        plain_item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="551",
            title="Plain",
        )
        other_item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="552",
            title="Other",
        )
        reviewed = DiaryEntry.objects.create(
            user=user,
            item=reviewed_item,
            consumed_at=timezone.now(),
            review_title="Title only",
            liked=True,
        )
        plain = DiaryEntry.objects.create(user=user, item=plain_item, consumed_at=timezone.now())
        other_entry = DiaryEntry.objects.create(user=other, item=other_item, consumed_at=timezone.now())
        update_diary_entry_tags(reviewed, ["mine"])
        update_diary_entry_tags(plain, ["also mine"])
        update_diary_entry_tags(other_entry, ["not mine"])
        self.client.force_authenticate(user)

        reviews = self.client.get("/api/v1/diary/", {"has_review": "true"})
        likes = self.client.get("/api/v1/diary/", {"liked": "true"})
        tags = self.client.get("/api/v1/diary/tags/", {"mine": "true"})

        self.assertEqual(reviews.status_code, status.HTTP_200_OK)
        self.assertEqual([entry["id"] for entry in reviews.data["results"]], [reviewed.id])
        self.assertEqual(likes.status_code, status.HTTP_200_OK)
        self.assertEqual([entry["id"] for entry in likes.data["results"]], [reviewed.id])
        self.assertEqual(tags.status_code, status.HTTP_200_OK)
        self.assertEqual({tag["name"] for tag in tags.data["results"]}, {"mine", "also mine"})

    def test_diary_tags_all_returns_more_than_autocomplete_cap(self):
        user = get_user_model().objects.create_user(username="tagged", password="strong-password-123")
        self.client.force_authenticate(user)

        for index in range(11):
            item = Item.objects.create(
                source=Sources.TMDB.value,
                media_type=MediaTypes.MOVIE.value,
                media_id=str(8000 + index),
                title=f"Tagged {index}",
            )
            entry = DiaryEntry.objects.create(user=user, item=item, consumed_at=timezone.now())
            update_diary_entry_tags(entry, [f"tag-{index:02d}"])

        capped = self.client.get("/api/v1/diary/tags/", {"mine": "true"})
        all_tags = self.client.get("/api/v1/diary/tags/", {"mine": "true", "all": "true"})

        self.assertEqual(capped.status_code, status.HTTP_200_OK)
        self.assertEqual(all_tags.status_code, status.HTTP_200_OK)
        self.assertEqual(len(capped.data["results"]), 10)
        self.assertEqual(len(all_tags.data["results"]), 11)

    @patch("app.providers.tmdb.get_poster_images")
    def test_media_posters_endpoint_requires_auth_and_returns_original_first(self, posters_mock):
        user = get_user_model().objects.create_user(username="poster", password="strong-password-123")
        Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Fight Club",
            image="https://example.com/original.jpg",
        )
        posters_mock.return_value = [
            {
                "url": "https://example.com/high.jpg",
                "thumbnail_url": "https://example.com/high-thumb.jpg",
                "width": 1000,
                "height": 1500,
                "aspect_ratio": 0.667,
                "vote_average": 8.5,
                "vote_count": 20,
                "language": "en",
            },
            {
                "url": "https://example.com/low.jpg",
                "thumbnail_url": "https://example.com/low-thumb.jpg",
                "width": 1000,
                "height": 1500,
                "aspect_ratio": 0.667,
                "vote_average": 7.0,
                "vote_count": 10,
                "language": None,
            },
        ]

        anonymous = self.client.get("/api/v1/media/tmdb/movie/550/posters/")
        self.client.force_authenticate(user)
        response = self.client.get("/api/v1/media/tmdb/movie/550/posters/")

        self.assertEqual(anonymous.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [poster["url"] for poster in response.data["posters"]],
            [
                "https://example.com/original.jpg",
                "https://example.com/high.jpg",
                "https://example.com/low.jpg",
            ],
        )
        self.assertTrue(response.data["posters"][0]["is_original"])

    @patch("app.providers.tmdb.get_poster_images")
    def test_media_season_posters_endpoint_returns_original_and_alternates(self, posters_mock):
        user = get_user_model().objects.create_user(username="seasonposter", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.SEASON.value,
            media_id="1399",
            title="Game of Thrones",
            image="https://example.com/original-season.jpg",
            season_number=1,
        )
        CustomPosterPreference.objects.create(
            user=user,
            item=item,
            custom_image_url="https://example.com/alt-season.jpg",
        )
        posters_mock.return_value = [
            {
                "url": "https://example.com/alt-season.jpg",
                "thumbnail_url": "https://example.com/alt-season-thumb.jpg",
                "width": 1000,
                "height": 1500,
                "aspect_ratio": 0.667,
                "vote_average": 8.5,
                "vote_count": 20,
                "language": "en",
            },
        ]

        self.client.force_authenticate(user)
        response = self.client.get("/api/v1/media/tmdb/season/1399/posters/?season_number=1")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        posters_mock.assert_called_once_with("1399", MediaTypes.SEASON.value, 1)
        self.assertEqual(
            [poster["url"] for poster in response.data["posters"]],
            ["https://example.com/original-season.jpg", "https://example.com/alt-season.jpg"],
        )
        self.assertTrue(response.data["posters"][0]["is_original"])
        self.assertFalse(response.data["posters"][0]["is_selected"])
        self.assertTrue(response.data["posters"][1]["is_selected"])

    @patch("api.services.media.provider_services.get_media_metadata")
    def test_media_book_posters_endpoint_returns_original_and_alternates(self, metadata_mock):
        user = get_user_model().objects.create_user(username="bookposter", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.OPENLIBRARY.value,
            media_type=MediaTypes.BOOK.value,
            media_id="OL7353617M",
            title="The Hobbit",
            image="https://example.com/original-book.jpg",
        )
        CustomPosterPreference.objects.create(
            user=user,
            item=item,
            custom_image_url="https://example.com/alt-book.jpg",
        )
        metadata_mock.return_value = {"details": {"isbn": ["9780547928227"]}}

        async def reliable_covers(*_args, **_kwargs):
            return [
                {"url": "https://example.com/original-book.jpg"},
                {
                    "url": "https://example.com/alt-book.jpg",
                    "thumbnail_url": "https://example.com/alt-book-thumb.jpg",
                    "width": 1000,
                    "height": 1500,
                    "aspect_ratio": 0.667,
                    "language": None,
                },
            ]

        self.client.force_authenticate(user)
        with patch("app.providers.openlibrary.get_reliable_covers_for_book", reliable_covers):
            response = self.client.get("/api/v1/media/openlibrary/book/OL7353617M/posters/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [poster["url"] for poster in response.data["posters"]],
            ["https://example.com/original-book.jpg", "https://example.com/alt-book.jpg"],
        )
        self.assertTrue(response.data["posters"][0]["is_original"])
        self.assertFalse(response.data["posters"][1]["is_original"])
        self.assertFalse(response.data["posters"][0]["is_selected"])
        self.assertTrue(response.data["posters"][1]["is_selected"])

    def test_media_posters_endpoint_rejects_unsupported_media(self):
        user = get_user_model().objects.create_user(username="poster2", password="strong-password-123")
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/media/mal/anime/1/posters/")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    @patch("app.providers.steamgriddb.get_game_posters")
    @patch("app.providers.igdb.get_game_covers")
    def test_media_game_posters_endpoint_returns_original_and_alternates(self, covers_mock, steamgriddb_posters_mock):
        user = get_user_model().objects.create_user(username="gameposter", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.IGDB.value,
            media_type=MediaTypes.GAME.value,
            media_id="1020",
            title="Space Game",
            image="https://example.com/original-game.jpg",
        )
        CustomPosterPreference.objects.create(
            user=user,
            item=item,
            custom_image_url="https://example.com/alt-game.jpg",
        )
        covers_mock.return_value = [
            {
                "url": "https://example.com/alt-game.jpg",
                "thumbnail_url": "https://example.com/alt-game-thumb.jpg",
                "width": 1000,
                "height": 1500,
                "aspect_ratio": 0.667,
                "language": None,
            },
        ]
        steamgriddb_posters_mock.return_value = [
            {
                "url": "https://example.com/steamgrid-game.jpg",
                "thumbnail_url": "https://example.com/steamgrid-game-thumb.jpg",
                "width": 600,
                "height": 900,
                "aspect_ratio": 0.667,
                "language": None,
            },
        ]
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/media/igdb/game/1020/posters/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [poster["url"] for poster in response.data["posters"]],
            [
                "https://example.com/original-game.jpg",
                "https://example.com/steamgrid-game.jpg",
                "https://example.com/alt-game.jpg",
            ],
        )
        self.assertTrue(response.data["posters"][0]["is_original"])
        self.assertTrue(response.data["posters"][2]["is_selected"])

    @patch("api.services.media.build_accent_palette", return_value={"accent": "#123456", "contrast": "#ffffff"})
    @patch("api.services.media.compute_and_store_poster_accent", return_value="#123456")
    def test_media_poster_save_updates_preference_and_item(self, _accent_mock, _palette_mock):
        user = get_user_model().objects.create_user(username="poster3", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.TV.value,
            media_id="1399",
            title="Game of Thrones",
            image="https://example.com/original.jpg",
        )
        self.client.force_authenticate(user)

        response = self.client.put(
            "/api/v1/media/tmdb/tv/1399/poster/",
            {"poster_url": "https://example.com/new.jpg"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["custom_poster_url"], "https://example.com/new.jpg")
        item.refresh_from_db()
        self.assertEqual(item.image, "https://example.com/new.jpg")
        self.assertEqual(item.poster_accent_color, "#123456")
        self.assertEqual(
            CustomPosterPreference.objects.get(user=user, item=item).custom_image_url,
            "https://example.com/new.jpg",
        )

    @patch("api.services.media.build_accent_palette", return_value={"accent": "#654321", "contrast": "#ffffff"})
    @patch("api.services.media.compute_and_store_poster_accent", return_value="#654321")
    def test_media_book_poster_save_updates_preference_and_item(self, _accent_mock, _palette_mock):
        user = get_user_model().objects.create_user(username="bookposter2", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.OPENLIBRARY.value,
            media_type=MediaTypes.BOOK.value,
            media_id="OL7353617M",
            title="The Hobbit",
            image="https://example.com/original-book.jpg",
        )
        self.client.force_authenticate(user)

        response = self.client.put(
            "/api/v1/media/openlibrary/book/OL7353617M/poster/",
            {"poster_url": "https://example.com/new-book.jpg"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["custom_poster_url"], "https://example.com/new-book.jpg")
        item.refresh_from_db()
        self.assertEqual(item.image, "https://example.com/new-book.jpg")
        self.assertEqual(item.poster_accent_color, "#654321")
        self.assertEqual(
            CustomPosterPreference.objects.get(user=user, item=item).custom_image_url,
            "https://example.com/new-book.jpg",
        )

    @patch("api.services.media.build_accent_palette", return_value={"accent": "#aabbcc", "contrast": "#000000"})
    @patch("api.services.media.compute_and_store_poster_accent", return_value="#aabbcc")
    def test_media_game_poster_save_updates_preference_and_item(self, _accent_mock, _palette_mock):
        user = get_user_model().objects.create_user(username="gameposter2", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.IGDB.value,
            media_type=MediaTypes.GAME.value,
            media_id="1020",
            title="Space Game",
            image="https://example.com/original-game.jpg",
        )
        self.client.force_authenticate(user)

        response = self.client.put(
            "/api/v1/media/igdb/game/1020/poster/",
            {"poster_url": "https://example.com/new-game.jpg"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["custom_poster_url"], "https://example.com/new-game.jpg")
        item.refresh_from_db()
        self.assertEqual(item.image, "https://example.com/new-game.jpg")
        self.assertEqual(item.poster_accent_color, "#aabbcc")

    @patch("api.services.media.build_accent_palette", return_value={"accent": "#abcdef", "contrast": "#000000"})
    @patch("api.services.media.compute_and_store_poster_accent", return_value="#abcdef")
    def test_media_season_poster_save_updates_preference_and_item(self, _accent_mock, _palette_mock):
        user = get_user_model().objects.create_user(username="seasonposter2", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.SEASON.value,
            media_id="1399",
            title="Game of Thrones",
            image="https://example.com/original-season.jpg",
            season_number=1,
        )
        self.client.force_authenticate(user)

        response = self.client.put(
            "/api/v1/media/tmdb/season/1399/poster/",
            {
                "poster_url": "https://example.com/new-season.jpg",
                "season_number": 1,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["custom_poster_url"], "https://example.com/new-season.jpg")
        item.refresh_from_db()
        self.assertEqual(item.image, "https://example.com/new-season.jpg")
        self.assertEqual(item.poster_accent_color, "#abcdef")
        self.assertEqual(
            CustomPosterPreference.objects.get(user=user, item=item).custom_image_url,
            "https://example.com/new-season.jpg",
        )

    @patch("api.services.media.provider_services.get_media_metadata")
    @patch("app.providers.tmdb.get_backdrop_images")
    def test_media_backdrops_endpoint_requires_auth_and_returns_original_first(self, backdrops_mock, metadata_mock):
        user = get_user_model().objects.create_user(username="backdrop", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Fight Club",
            image="https://example.com/poster.jpg",
        )
        CustomBackdropPreference.objects.create(
            user=user,
            item=item,
            custom_image_url="https://example.com/high.jpg",
        )
        metadata_mock.return_value = {
            "title": "Fight Club",
            "image": "https://example.com/poster.jpg",
            "backdrop_path": "/original.jpg",
        }
        backdrops_mock.return_value = [
            {
                "url": "https://example.com/high.jpg",
                "thumbnail_url": "https://example.com/high-thumb.jpg",
                "width": 1920,
                "height": 1080,
                "aspect_ratio": 1.778,
                "vote_average": 8.5,
                "vote_count": 20,
                "language": "en",
            },
        ]

        anonymous = self.client.get("/api/v1/media/tmdb/movie/550/backdrops/")
        self.client.force_authenticate(user)
        response = self.client.get("/api/v1/media/tmdb/movie/550/backdrops/")

        self.assertEqual(anonymous.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [backdrop["url"] for backdrop in response.data["backdrops"]],
            [
                "https://image.tmdb.org/t/p/original/original.jpg",
                "https://example.com/high.jpg",
            ],
        )
        self.assertTrue(response.data["backdrops"][0]["is_original"])
        self.assertFalse(response.data["backdrops"][0]["is_selected"])
        self.assertTrue(response.data["backdrops"][1]["is_selected"])

    @patch("api.services.media.provider_services.get_media_metadata")
    @patch("app.providers.tmdb.get_backdrop_images")
    def test_media_backdrops_endpoint_selects_effective_tmdb_default(self, backdrops_mock, metadata_mock):
        user = get_user_model().objects.create_user(username="backdrop-default", password="strong-password-123")
        Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Fight Club",
            image="https://example.com/poster.jpg",
        )
        metadata_mock.return_value = {
            "title": "Fight Club",
            "image": "https://example.com/poster.jpg",
            "backdrop_path": "/original.jpg",
        }
        backdrops_mock.return_value = [
            {
                "url": "https://image.tmdb.org/t/p/original/original.jpg",
                "thumbnail_url": "https://example.com/original-thumb.jpg",
                "width": 1920,
                "height": 1080,
                "aspect_ratio": 1.778,
                "vote_average": 9,
                "vote_count": 30,
                "language": "en",
            },
            {
                "url": "https://example.com/high-en.jpg",
                "thumbnail_url": "https://example.com/high-en-thumb.jpg",
                "width": 1920,
                "height": 1080,
                "aspect_ratio": 1.778,
                "vote_average": 10,
                "vote_count": 40,
                "language": "en",
            },
            {
                "url": "https://example.com/first-no-language.jpg",
                "thumbnail_url": "https://example.com/first-no-language-thumb.jpg",
                "width": 1920,
                "height": 1080,
                "aspect_ratio": 1.778,
                "vote_average": 9,
                "vote_count": 30,
                "language": None,
            },
            {
                "url": "https://example.com/second.jpg",
                "thumbnail_url": "https://example.com/second-thumb.jpg",
                "width": 1920,
                "height": 1080,
                "aspect_ratio": 1.778,
                "vote_average": 8,
                "vote_count": 20,
                "language": None,
            },
        ]
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/media/tmdb/movie/550/backdrops/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        selected = [backdrop["url"] for backdrop in response.data["backdrops"] if backdrop["is_selected"]]
        self.assertEqual(selected, ["https://example.com/second.jpg"])

    @patch("api.services.media.provider_services.get_media_metadata")
    @patch("app.providers.tmdb.get_season_backdrop_images")
    def test_media_backdrops_endpoint_supports_seasons(self, backdrops_mock, metadata_mock):
        user = get_user_model().objects.create_user(username="season-backdrop", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.SEASON.value,
            media_id="1399",
            title="Game of Thrones",
            image="https://example.com/poster.jpg",
            season_number=1,
        )
        CustomBackdropPreference.objects.create(
            user=user,
            item=item,
            custom_image_url="https://example.com/episode-2.jpg",
        )
        metadata_mock.return_value = {
            "season/1": {
                "season_title": "Season 1",
                "image": "https://example.com/poster.jpg",
                "episodes": [],
            },
        }
        backdrops_mock.return_value = [
            {
                "url": "https://example.com/episode-1.jpg",
                "thumbnail_url": "https://example.com/episode-1-thumb.jpg",
                "width": 1920,
                "height": 1080,
                "aspect_ratio": 1.778,
                "vote_average": 0,
                "vote_count": 0,
                "language": None,
                "episode_number": 1,
            },
            {
                "url": "https://example.com/episode-2.jpg",
                "thumbnail_url": "https://example.com/episode-2-thumb.jpg",
                "width": 1920,
                "height": 1080,
                "aspect_ratio": 1.778,
                "vote_average": 0,
                "vote_count": 0,
                "language": None,
                "episode_number": 2,
            },
        ]
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/media/tmdb/season/1399/backdrops/?season_number=1")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [backdrop["url"] for backdrop in response.data["backdrops"]],
            [
                "https://example.com/episode-1.jpg",
                "https://example.com/episode-2.jpg",
            ],
        )
        self.assertTrue(response.data["backdrops"][1]["is_selected"])
        backdrops_mock.assert_called_once_with("1399", 1)

    def test_media_backdrops_endpoint_rejects_unsupported_media(self):
        user = get_user_model().objects.create_user(username="backdrop2", password="strong-password-123")
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/media/mal/anime/1/backdrops/")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    @patch("app.providers.steam.get_metacritic_rating", return_value=None)
    @patch("app.providers.steamgriddb.get_game_logo")
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_media_detail_includes_steamgriddb_logo_fields(self, metadata_mock, logo_mock, _metacritic_mock):
        metadata_mock.return_value = {
            "media_id": "1020",
            "media_type": "game",
            "source": "igdb",
            "title": "Space Game",
            "image": "https://example.com/space-game.jpg",
        }
        logo_mock.return_value = {
            "url": "https://cdn2.steamgriddb.com/logo/space.png",
            "width": 600,
            "height": 215,
            "aspect_ratio": 2.791,
        }

        response = self.client.get("/api/v1/media/igdb/game/1020/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["logo_url"], "https://cdn2.steamgriddb.com/logo/space.png")
        self.assertEqual(response.data["logo_width"], 600)
        self.assertEqual(response.data["logo_height"], 215)
        self.assertEqual(response.data["logo_aspect_ratio"], 2.791)
        logo_mock.assert_called_once_with("1020")

    @patch("api.services.media.provider_services.get_media_metadata")
    @patch("app.providers.steamgriddb.get_game_backdrops")
    @patch("app.providers.igdb.get_game_backdrops")
    def test_media_game_backdrops_endpoint_returns_artworks(
        self,
        backdrops_mock,
        steamgriddb_backdrops_mock,
        metadata_mock,
    ):
        user = get_user_model().objects.create_user(username="gamebackdrop", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.IGDB.value,
            media_type=MediaTypes.GAME.value,
            media_id="1020",
            title="Space Game",
            image="https://example.com/poster.jpg",
        )
        CustomBackdropPreference.objects.create(
            user=user,
            item=item,
            custom_image_url="https://example.com/alt-art.jpg",
        )
        metadata_mock.return_value = {
            "title": "Space Game",
            "image": "https://example.com/poster.jpg",
            "artworks": [{"image_id": "original-art"}],
        }
        backdrops_mock.return_value = [
            {
                "url": "https://example.com/alt-art.jpg",
                "thumbnail_url": "https://example.com/alt-art-thumb.jpg",
                "width": 1920,
                "height": 1080,
                "aspect_ratio": 1.778,
                "language": None,
            },
        ]
        steamgriddb_backdrops_mock.return_value = [
            {
                "url": "https://example.com/steamgrid-hero.jpg",
                "thumbnail_url": "https://example.com/steamgrid-hero-thumb.jpg",
                "width": 1920,
                "height": 620,
                "aspect_ratio": 3.097,
                "language": None,
            },
        ]
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/media/igdb/game/1020/backdrops/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [backdrop["url"] for backdrop in response.data["backdrops"]],
            [
                "https://images.igdb.com/igdb/image/upload/t_original/original-art.jpg",
                "https://example.com/steamgrid-hero.jpg",
                "https://example.com/alt-art.jpg",
            ],
        )
        self.assertTrue(response.data["backdrops"][0]["is_original"])
        self.assertTrue(response.data["backdrops"][2]["is_selected"])

    def test_media_backdrop_save_updates_preference_without_changing_item_image(self):
        user = get_user_model().objects.create_user(username="backdrop3", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.TV.value,
            media_id="1399",
            title="Game of Thrones",
            image="https://example.com/original-poster.jpg",
        )
        self.client.force_authenticate(user)

        response = self.client.put(
            "/api/v1/media/tmdb/tv/1399/backdrop/",
            {"backdrop_url": "https://example.com/new-backdrop.jpg"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["custom_backdrop_url"], "https://example.com/new-backdrop.jpg")
        item.refresh_from_db()
        self.assertEqual(item.image, "https://example.com/original-poster.jpg")
        self.assertEqual(
            CustomBackdropPreference.objects.get(user=user, item=item).custom_image_url,
            "https://example.com/new-backdrop.jpg",
        )

    def test_media_game_backdrop_save_updates_preference_without_changing_item_image(self):
        user = get_user_model().objects.create_user(username="gamebackdrop2", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.IGDB.value,
            media_type=MediaTypes.GAME.value,
            media_id="1020",
            title="Space Game",
            image="https://example.com/original-game.jpg",
        )
        self.client.force_authenticate(user)

        response = self.client.put(
            "/api/v1/media/igdb/game/1020/backdrop/",
            {"backdrop_url": "https://example.com/new-game-backdrop.jpg"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["custom_backdrop_url"], "https://example.com/new-game-backdrop.jpg")
        item.refresh_from_db()
        self.assertEqual(item.image, "https://example.com/original-game.jpg")
        self.assertEqual(
            CustomBackdropPreference.objects.get(user=user, item=item).custom_image_url,
            "https://example.com/new-game-backdrop.jpg",
        )

    def test_media_season_backdrop_save_updates_preference_without_changing_item_image(self):
        user = get_user_model().objects.create_user(username="seasonbackdrop2", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.SEASON.value,
            media_id="1399",
            title="Game of Thrones",
            image="https://example.com/original-season.jpg",
            season_number=1,
        )
        self.client.force_authenticate(user)

        response = self.client.put(
            "/api/v1/media/tmdb/season/1399/backdrop/",
            {
                "backdrop_url": "https://example.com/new-season-backdrop.jpg",
                "season_number": 1,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["custom_backdrop_url"], "https://example.com/new-season-backdrop.jpg")
        item.refresh_from_db()
        self.assertEqual(item.image, "https://example.com/original-season.jpg")
        self.assertEqual(
            CustomBackdropPreference.objects.get(user=user, item=item).custom_image_url,
            "https://example.com/new-season-backdrop.jpg",
        )

    @patch("app.providers.tmdb.get_title_logo", return_value=None)
    @patch("app.providers.tmdb.get_backdrop_images", return_value=[])
    @patch("app.providers.mdblist.get_media_ratings", return_value={})
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_media_detail_includes_custom_backdrop_url_when_preference_exists(
        self,
        metadata_mock,
        _ratings_mock,
        _backdrops_mock,
        _logo_mock,
    ):
        user = get_user_model().objects.create_user(username="backdrop4", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Fight Club",
            image="https://example.com/poster.jpg",
        )
        CustomBackdropPreference.objects.create(
            user=user,
            item=item,
            custom_image_url="https://example.com/custom-backdrop.jpg",
        )
        metadata_mock.return_value = {
            "media_id": "550",
            "media_type": "movie",
            "source": "tmdb",
            "title": "Fight Club",
            "image": "https://example.com/poster.jpg",
            "backdrop_path": "/default-backdrop.jpg",
        }
        self.client.force_authenticate(user)

        response = self.client.get("/api/v1/media/tmdb/movie/550/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["backdrop_url"], "https://image.tmdb.org/t/p/original/default-backdrop.jpg")
        self.assertEqual(response.data["custom_backdrop_url"], "https://example.com/custom-backdrop.jpg")

    @override_settings(SPINE_CURATOR_USERNAME="curator")
    @patch("app.providers.tmdb.get_title_logo", return_value=None)
    @patch("app.providers.tmdb.get_backdrop_images")
    @patch("app.providers.mdblist.get_media_ratings", return_value={})
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_media_detail_uses_curator_backdrop_as_default(
        self,
        metadata_mock,
        _ratings_mock,
        backdrops_mock,
        _logo_mock,
    ):
        curator = get_user_model().objects.create_user(username="curator", password="strong-password-123")
        viewer = get_user_model().objects.create_user(username="viewer-curated", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Fight Club",
            image="https://example.com/poster.jpg",
        )
        CustomBackdropPreference.objects.create(
            user=curator,
            item=item,
            custom_image_url="https://example.com/curated-backdrop.jpg",
        )
        metadata_mock.return_value = {
            "media_id": "550",
            "media_type": "movie",
            "source": "tmdb",
            "title": "Fight Club",
            "image": "https://example.com/poster.jpg",
            "backdrop_path": "/default-backdrop.jpg",
        }
        self.client.force_authenticate(viewer)

        response = self.client.get("/api/v1/media/tmdb/movie/550/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["backdrop_url"], "https://example.com/curated-backdrop.jpg")
        self.assertIsNone(response.data["custom_backdrop_url"])
        backdrops_mock.assert_not_called()

    @patch("app.providers.tmdb.get_title_logo", return_value=None)
    @patch("app.providers.tmdb.get_backdrop_images")
    @patch("app.providers.mdblist.get_media_ratings", return_value={})
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_media_detail_uses_second_no_language_tmdb_backdrop_when_uncurated(
        self,
        metadata_mock,
        _ratings_mock,
        backdrops_mock,
        _logo_mock,
    ):
        metadata_mock.return_value = {
            "media_id": "550",
            "media_type": "movie",
            "source": "tmdb",
            "title": "Fight Club",
            "image": "https://example.com/poster.jpg",
            "backdrop_path": "/default-backdrop.jpg",
        }
        backdrops_mock.return_value = [
            {"url": "https://example.com/high-en.jpg", "language": "en"},
            {"url": "https://example.com/first.jpg", "language": None},
            {"url": "https://example.com/second.jpg", "language": None},
        ]

        response = self.client.get("/api/v1/media/tmdb/movie/550/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["backdrop_url"], "https://example.com/second.jpg")

    @patch("app.providers.tmdb.get_title_logo", return_value=None)
    @patch("app.providers.tmdb.get_backdrop_images")
    @patch("app.providers.mdblist.get_media_ratings", return_value={})
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_media_detail_falls_back_to_raw_tmdb_backdrop_with_one_candidate(
        self,
        metadata_mock,
        _ratings_mock,
        backdrops_mock,
        _logo_mock,
    ):
        metadata_mock.return_value = {
            "media_id": "550",
            "media_type": "movie",
            "source": "tmdb",
            "title": "Fight Club",
            "image": "https://example.com/poster.jpg",
            "backdrop_path": "/default-backdrop.jpg",
        }
        backdrops_mock.return_value = [{"url": "https://example.com/only.jpg"}]

        response = self.client.get("/api/v1/media/tmdb/movie/550/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["backdrop_url"], "https://image.tmdb.org/t/p/original/default-backdrop.jpg")

    @patch("app.providers.tmdb.get_title_logo", return_value=None)
    @patch("app.providers.tmdb.get_backdrop_images")
    @patch("app.providers.mdblist.get_media_ratings", return_value={})
    @patch("api.services.media.provider_services.get_media_metadata")
    def test_media_detail_uses_only_tmdb_backdrop_when_raw_default_is_missing(
        self,
        metadata_mock,
        _ratings_mock,
        backdrops_mock,
        _logo_mock,
    ):
        metadata_mock.return_value = {
            "media_id": "550",
            "media_type": "movie",
            "source": "tmdb",
            "title": "Fight Club",
            "image": "https://example.com/poster.jpg",
        }
        backdrops_mock.return_value = [{"url": "https://example.com/only.jpg"}]

        response = self.client.get("/api/v1/media/tmdb/movie/550/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["backdrop_url"], "https://example.com/only.jpg")

    @override_settings(SPINE_CURATOR_USERNAME="curator")
    def test_curator_backdrop_save_does_not_overwrite_other_user_preferences(self):
        curator = get_user_model().objects.create_user(username="curator", password="strong-password-123")
        viewer = get_user_model().objects.create_user(username="viewer-custom", password="strong-password-123")
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.TV.value,
            media_id="1399",
            title="Game of Thrones",
            image="https://example.com/poster.jpg",
        )
        CustomBackdropPreference.objects.create(
            user=viewer,
            item=item,
            custom_image_url="https://example.com/viewer.jpg",
        )
        self.client.force_authenticate(curator)

        response = self.client.put(
            "/api/v1/media/tmdb/tv/1399/backdrop/",
            {"backdrop_url": "https://example.com/curator.jpg"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            CustomBackdropPreference.objects.get(user=curator, item=item).custom_image_url,
            "https://example.com/curator.jpg",
        )
        self.assertEqual(
            CustomBackdropPreference.objects.get(user=viewer, item=item).custom_image_url,
            "https://example.com/viewer.jpg",
        )
