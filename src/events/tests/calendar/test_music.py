from unittest.mock import patch

import requests
from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone

from app.models import Item, MediaTypes, Music, Sources, Status
from app.providers import services
from events.calendar.helpers import date_parser
from events.calendar.main import fetch_releases, process_items
from events.calendar.other import process_other
from events.calendar.selectors import get_items_to_process
from events.models import Event
from events.notifications import format_notification


class MusicReleaseEventTests(TestCase):
    def setUp(self):
        self.item = Item.objects.create(
            media_id="3bd76d40-7f0e-36b7-9348-91a33afee20e",
            source=Sources.MUSICBRAINZ.value,
            media_type=MediaTypes.MUSIC.value,
            title="Year Zero",
            image="https://example.com/year-zero.jpg",
        )

    @patch("events.calendar.other.services.get_media_metadata")
    def test_release_date_precision_and_past_events(self, get_media_metadata):
        cases = (
            ("2027-12-17", "2027-12-17"),
            ("2027-06", "2027-06-01"),
            ("2028", "2028-01-01"),
            ("2007-04-13", "2007-04-13"),
        )

        for release_date, expected in cases:
            with self.subTest(release_date=release_date):
                get_media_metadata.return_value = {
                    "max_progress": 1,
                    "details": {
                        "first_release_date": release_date,
                        "representative_release_date": "2030-01-01",
                    },
                }
                events = []

                process_other(self.item, events)

                self.assertEqual(len(events), 1)
                self.assertIsNone(events[0].content_number)
                self.assertEqual(events[0].datetime, date_parser(expected))
                self.assertEqual(str(events[0]), "Year Zero")

    @patch("events.calendar.other.services.get_media_metadata")
    def test_unknown_and_invalid_dates_create_no_event(self, get_media_metadata):
        for details in (
            {},
            {"first_release_date": None},
            {"first_release_date": ""},
            {"first_release_date": "not-a-date"},
        ):
            with self.subTest(details=details):
                get_media_metadata.return_value = {
                    "max_progress": 1,
                    "details": details,
                }
                events = []

                process_other(self.item, events)

                self.assertEqual(events, [])

    @patch("events.calendar.other.services.get_media_metadata")
    def test_rerun_updates_one_unnumbered_event(self, get_media_metadata):
        get_media_metadata.side_effect = (
            {
                "max_progress": 1,
                "details": {"first_release_date": "2027-12-17"},
            },
            {
                "max_progress": 1,
                "details": {"first_release_date": "2027-12-18"},
            },
        )

        fetch_releases(items_to_process=[self.item])
        fetch_releases(items_to_process=[self.item])

        event = Event.objects.get(item=self.item)
        self.assertIsNone(event.content_number)
        self.assertEqual(event.datetime, date_parser("2027-12-18"))

    @patch("events.calendar.other.services.get_media_metadata")
    def test_musicbrainz_timeout_does_not_stop_batch(self, get_media_metadata):
        movie = Item.objects.create(
            media_id="238",
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            title="The Godfather",
            image="https://example.com/godfather.jpg",
        )
        get_media_metadata.side_effect = (
            services.ProviderAPIError(
                Sources.MUSICBRAINZ.value,
                requests.exceptions.Timeout("timed out"),
            ),
            {
                "max_progress": 1,
                "details": {"release_date": "1972-03-24"},
            },
        )

        events = process_items([self.item, movie])

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].item, movie)

    @patch("events.calendar.selectors.tmdb.movie_changes", return_value=set())
    @patch("events.calendar.selectors.tmdb.tv_changes", return_value=set())
    def test_scheduled_refresh_selects_new_and_future_music(
        self,
        _tv_changes,
        _movie_changes,
    ):
        user = get_user_model().objects.create_user(username="listener")
        Music.objects.bulk_create(
            [Music(item=self.item, user=user, status=Status.PLANNING.value)],
        )

        self.assertIn(self.item, get_items_to_process(user))

        event = Event.objects.create(
            item=self.item,
            content_number=None,
            datetime=timezone.now() + timezone.timedelta(days=30),
        )
        self.assertIn(self.item, get_items_to_process(user))

        event.datetime = timezone.now() - timezone.timedelta(days=30)
        event.save(update_fields=["datetime"])
        self.assertNotIn(self.item, get_items_to_process(user))
        self.assertTrue(Event.objects.filter(pk=event.pk).exists())

    @patch("events.tasks.reload_calendar.delay")
    def test_status_change_enqueues_release_fetch(self, reload_calendar):
        user = get_user_model().objects.create_user(username="listener")
        Music.objects.bulk_create(
            [Music(item=self.item, user=user, status=Status.PLANNING.value)],
        )
        music = Music.objects.get(item=self.item, user=user)

        music.status = Status.PAUSED.value
        music.save()

        reload_calendar.assert_called_once_with(items_to_process=[self.item])

    def test_music_notification_uses_listen_wording(self):
        event = Event(
            item=self.item,
            content_number=None,
            datetime=date_parser("2027-12-17"),
        )

        notification = format_notification([event])

        self.assertIn("Year Zero is available to listen", notification)
        self.assertNotIn("track", notification.lower())
        self.assertNotIn("episode", notification.lower())
        self.assertNotIn("watch", notification.lower())
