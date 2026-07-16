from datetime import UTC, datetime
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse

from app.forms import MusicForm
from app.models import DiaryEntry, Item, MediaTypes, Music, Sources, Status


class MusicTrackingDiaryWebTests(TestCase):
    """Albums use the shared tracking and diary web flows."""

    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="web-music",
            password="password",
        )
        self.client.login(username="web-music", password="password")
        self.media_id = "3bd76d40-7f0e-36b7-9348-91a33afee20e"
        self.item = Item.objects.create(
            source=Sources.MUSICBRAINZ.value,
            media_type=MediaTypes.MUSIC.value,
            media_id=self.media_id,
            title="Year Zero",
            image="https://example.com/year-zero.jpg",
        )

    def test_music_form_has_album_status_labels_and_no_progress(self):
        form = MusicForm()

        self.assertNotIn("progress", form.fields)
        self.assertIn(
            (Status.IN_PROGRESS.value, "Listening"),
            list(form.fields["status"].choices),
        )
        self.assertIn(
            (Status.COMPLETED.value, "Listened"),
            list(form.fields["status"].choices),
        )

    def test_generic_tracking_create_list_update_and_progress_rejection(self):
        metadata = {
            "title": self.item.title,
            "image": self.item.image,
            "max_progress": 1,
        }
        with (
            patch("app.providers.services.get_media_metadata", return_value=metadata),
            patch("app.models.Item.fetch_releases"),
        ):
            created = self.client.post(
                reverse("media_save"),
                {
                    "media_id": self.media_id,
                    "source": Sources.MUSICBRAINZ.value,
                    "media_type": MediaTypes.MUSIC.value,
                    "status": Status.IN_PROGRESS.value,
                    "score": "8.5",
                    "start_date": "2025-01-01 00:00:00",
                    "notes": "Listen loudly.",
                },
                HTTP_REFERER="/",
            )
            music = Music.objects.get(user=self.user, item=self.item)
            paused = self.client.post(
                reverse(
                    "pause_media",
                    args=[Sources.MUSICBRAINZ.value, MediaTypes.MUSIC.value, self.media_id],
                ),
            )
            music.refresh_from_db()
            paused_status = music.status
            resumed = self.client.post(
                reverse(
                    "resume_media",
                    args=[Sources.MUSICBRAINZ.value, MediaTypes.MUSIC.value, self.media_id],
                ),
            )
            music.refresh_from_db()
            resumed_status = music.status
            dropped = self.client.post(
                reverse(
                    "drop_media",
                    args=[Sources.MUSICBRAINZ.value, MediaTypes.MUSIC.value, self.media_id],
                ),
            )
            music.refresh_from_db()
            dropped_status = music.status
            resumed_after_drop = self.client.post(
                reverse(
                    "resume_media",
                    args=[Sources.MUSICBRAINZ.value, MediaTypes.MUSIC.value, self.media_id],
                ),
            )
            music.refresh_from_db()
            listed = self.client.get(
                reverse("medialist", args=[MediaTypes.MUSIC.value]),
                {"layout": "table"},
            )
            rejected = self.client.post(
                reverse(
                    "progress_edit",
                    kwargs={
                        "media_type": MediaTypes.MUSIC.value,
                        "instance_id": music.id,
                    },
                ),
                {"operation": "increase"},
            )

        self.assertEqual(created.status_code, 302)
        self.assertEqual(music.status, Status.IN_PROGRESS.value)
        self.assertEqual(music.score, 8.5)
        self.assertEqual(music.notes, "Listen loudly.")
        self.assertEqual(paused.status_code, 200)
        self.assertEqual(paused_status, Status.PAUSED.value)
        self.assertEqual(resumed.status_code, 200)
        self.assertEqual(resumed_status, Status.IN_PROGRESS.value)
        self.assertEqual(dropped.status_code, 200)
        self.assertEqual(dropped_status, Status.DROPPED.value)
        self.assertEqual(resumed_after_drop.status_code, 200)
        self.assertEqual(music.status, Status.IN_PROGRESS.value)
        self.assertEqual(listed.status_code, 200)
        self.assertContains(listed, "Listening")
        self.assertIn(
            (Status.COMPLETED.value, "Listened"),
            listed.context["status_choices"],
        )
        self.assertEqual(rejected.status_code, 400)
        self.assertContains(rejected, "does not support progress updates", status_code=400)

    def test_log_modal_and_shared_create_update_flow_support_album_fields(self):
        metadata = {
            "title": self.item.title,
            "image": self.item.image,
            "max_progress": 1,
        }
        modal_url = reverse(
            "log_modal",
            args=[Sources.MUSICBRAINZ.value, MediaTypes.MUSIC.value, self.media_id],
        )
        create_url = reverse(
            "add_movie_diary_entry",
            args=[Sources.MUSICBRAINZ.value, MediaTypes.MUSIC.value, self.media_id],
        )

        modal = self.client.get(modal_url)
        repeat_modal = self.client.get(modal_url, {"relisten": "1"})

        with (
            patch("app.providers.services.get_media_metadata", return_value=metadata),
            patch("app.models.Item.fetch_releases"),
        ):
            created = self.client.post(
                create_url,
                {
                    "watch_date": "2025-04-05",
                    "rating": "9",
                    "review_title": "A loud future",
                    "review": "Still sounds dangerous.",
                    "liked": "true",
                    "is_rewatch": "on",
                    "contains_spoilers": "on",
                    "visibility": "followers",
                    "tags": "industrial, headphones",
                    "auto_mark_consumed": "true",
                },
            )

        self.assertEqual(modal.status_code, 200)
        self.assertContains(modal, "Log Album")
        self.assertContains(modal, "Date listened")
        self.assertContains(modal, 'name="review_title"')
        self.assertContains(modal, 'name="visibility"')
        self.assertContains(modal, 'name="contains_spoilers"')
        self.assertContains(repeat_modal, "Relisten")

        self.assertEqual(created.status_code, 200)
        entry = DiaryEntry.objects.get(user=self.user, item=self.item)
        self.assertEqual(entry.rating, 9)
        self.assertEqual(entry.review_title, "A loud future")
        self.assertEqual(entry.review, "Still sounds dangerous.")
        self.assertTrue(entry.liked)
        self.assertTrue(entry.is_rewatch)
        self.assertTrue(entry.contains_spoilers)
        self.assertEqual(entry.visibility, "followers")
        self.assertCountEqual(
            entry.tags.values_list("name", flat=True),
            ["industrial", "headphones"],
        )

        music = Music.objects.get(user=self.user, item=self.item)
        self.assertEqual(music.status, Status.COMPLETED.value)
        self.assertEqual(
            music.end_date,
            datetime(2025, 4, 5, 23, 59, 59, 999999, tzinfo=UTC),
        )

        updated = self.client.post(
            reverse("update_diary_entry", args=[entry.id]),
            {
                "watch_date": "2025-04-06",
                "rating": "8.5",
                "review_title": "A quieter pass",
                "review": "Different details.",
                "liked": "false",
                "is_rewatch": "on",
                "visibility": "private",
                "tags": "relisten",
                "current_media_type": MediaTypes.MUSIC.value,
            },
        )

        self.assertEqual(updated.status_code, 200)
        entry.refresh_from_db()
        self.assertEqual(entry.review_title, "A quieter pass")
        self.assertEqual(entry.rating, 8.5)
        self.assertEqual(entry.visibility, "private")
        self.assertFalse(entry.contains_spoilers)
        self.assertEqual(list(entry.tags.values_list("name", flat=True)), ["relisten"])

    @patch("app.views.compute_and_store_poster_accent", return_value="#333333")
    @patch("app.views.services.get_media_metadata")
    def test_album_detail_reuses_generic_actions_and_existing_logs(
        self,
        metadata_mock,
        _accent_mock,
    ):
        metadata_mock.return_value = {
            "media_id": self.media_id,
            "title": self.item.title,
            "media_type": MediaTypes.MUSIC.value,
            "source": Sources.MUSICBRAINZ.value,
            "image": self.item.image,
            "related": {},
        }
        with (
            patch(
                "app.providers.services.get_media_metadata",
                return_value={"max_progress": 1},
            ),
            patch("app.models.Item.fetch_releases"),
        ):
            Music.objects.create(
                user=self.user,
                item=self.item,
                status=Status.COMPLETED.value,
            )
        DiaryEntry.objects.create(
            user=self.user,
            item=self.item,
            consumed_at=datetime(2025, 5, 1, tzinfo=UTC),
        )

        response = self.client.get(
            reverse(
                "media_details",
                args=[
                    Sources.MUSICBRAINZ.value,
                    MediaTypes.MUSIC.value,
                    self.media_id,
                    "year-zero",
                ],
            ),
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.context["diary_entries"]), 1)
        self.assertContains(response, "Listened")
        self.assertContains(response, "Relisten")
        self.assertNotContains(response, "Watching")

    def test_manual_music_creation_uses_generic_item_and_tracking_forms(self):
        response = self.client.post(
            reverse("create_entry"),
            {
                "media_type": MediaTypes.MUSIC.value,
                "title": "Manual Album",
                "status": Status.IN_PROGRESS.value,
                "score": "8.5",
            },
        )

        self.assertEqual(response.status_code, 302)
        music = Music.objects.get(
            user=self.user,
            item__source=Sources.MANUAL.value,
            item__title="Manual Album",
        )
        self.assertEqual(music.status, Status.IN_PROGRESS.value)
        self.assertEqual(music.score, 8.5)
