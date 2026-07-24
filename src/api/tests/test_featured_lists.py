from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework import status
from rest_framework.test import APIClient

from app.models import Item, MediaTypes, Sources
from lists.models import CustomList, CustomListItem


class FeaturedListsApiTests(TestCase):
    """Featured-list discovery API contract."""

    def test_returns_only_public_featured_lists_with_previews(self):
        owner = get_user_model().objects.create_user(username="Spine")
        viewer = get_user_model().objects.create_user(username="viewer")
        featured = CustomList.objects.create(
            owner=owner,
            name="Featured",
            visibility=CustomList.Visibility.PUBLIC,
            is_featured=True,
            featured_position=1,
        )
        CustomList.objects.create(
            owner=owner,
            name="Private",
            visibility=CustomList.Visibility.PRIVATE,
            is_featured=True,
        )
        item = Item.objects.create(
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            media_id="550",
            title="Fight Club",
            image="https://example.com/fight-club.jpg",
        )
        CustomListItem.objects.create(custom_list=featured, item=item, position=1)
        client = APIClient()
        client.force_authenticate(viewer)

        response = client.get("/api/v1/lists/featured/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["count"], 1)
        self.assertEqual(response.data["results"][0]["name"], "Featured")
        self.assertEqual(response.data["results"][0]["owner"]["username"], "Spine")
        self.assertEqual(response.data["results"][0]["preview_items"][0]["title"], "Fight Club")
