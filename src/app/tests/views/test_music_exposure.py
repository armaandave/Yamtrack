from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase, override_settings
from django.urls import reverse

from app.models import MediaTypes, Sources
from app.templatetags.app_tags import get_search_media_types, get_sidebar_media_types


@override_settings(MUSIC_ENABLED=False)
class MusicWebExposureTests(TestCase):
    """Disabled music stays out of server-rendered client surfaces."""

    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="web-listener",
            password="password",
        )
        self.client.login(username="web-listener", password="password")

    @patch("app.views.services.get_media_metadata")
    @patch("app.views.services.search")
    def test_music_search_detail_and_list_are_not_found(
        self,
        search_mock,
        metadata_mock,
    ):
        search = self.client.get(reverse("search"), {"media_type": "music", "q": "year zero"})
        detail = self.client.get(
            reverse(
                "media_details",
                args=[
                    Sources.MUSICBRAINZ.value,
                    MediaTypes.MUSIC.value,
                    "3bd76d40-7f0e-36b7-9348-91a33afee20e",
                    "year-zero",
                ],
            ),
        )
        media_list = self.client.get(reverse("medialist", args=[MediaTypes.MUSIC.value]))

        self.assertEqual(search.status_code, 404)
        self.assertEqual(detail.status_code, 404)
        self.assertEqual(media_list.status_code, 404)
        search_mock.assert_not_called()
        metadata_mock.assert_not_called()

    def test_manual_entry_hides_and_rejects_music(self):
        form = self.client.get(reverse("create_entry"))
        submitted = self.client.post(
            reverse("create_entry"),
            {"media_type": MediaTypes.MUSIC.value, "title": "Year Zero"},
        )

        self.assertNotIn(MediaTypes.MUSIC.value, form.context["media_types"])
        self.assertEqual(submitted.status_code, 404)

    @patch("app.views.services.get_media_metadata")
    def test_direct_music_tracking_is_not_found(self, metadata_mock):
        modal = self.client.get(
            reverse(
                "track_modal",
                args=[
                    Sources.MUSICBRAINZ.value,
                    MediaTypes.MUSIC.value,
                    "3bd76d40-7f0e-36b7-9348-91a33afee20e",
                ],
            ),
            {"return_url": "/"},
        )
        saved = self.client.post(
            reverse("media_save"),
            {
                "media_id": "3bd76d40-7f0e-36b7-9348-91a33afee20e",
                "source": Sources.MUSICBRAINZ.value,
                "media_type": MediaTypes.MUSIC.value,
            },
        )

        self.assertEqual(modal.status_code, 404)
        self.assertEqual(saved.status_code, 404)
        metadata_mock.assert_not_called()

    def test_navigation_helpers_hide_music(self):
        search_types = get_search_media_types(self.user)
        sidebar_types = get_sidebar_media_types(self.user)

        self.assertNotIn(MediaTypes.MUSIC.value, [item["value"] for item in search_types])
        self.assertNotIn(
            MediaTypes.MUSIC.value,
            [item["media_type"] for item in sidebar_types],
        )

    @patch("users.views.tmdb.watch_provider_regions", return_value=[])
    def test_web_preferences_hide_music_and_preserve_its_value(self, _regions_mock):
        form = self.client.get(reverse("preferences"))
        saved = self.client.post(
            reverse("preferences"),
            {"media_types_checkboxes": [MediaTypes.MOVIE.value]},
        )

        self.assertNotIn(MediaTypes.MUSIC.value, form.context["media_types"])
        self.assertEqual(saved.status_code, 302)
        self.user.refresh_from_db()
        self.assertTrue(self.user.music_enabled)
