from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from django.test import TestCase
from django.utils import timezone

from app.models import DiaryEntry, Item, MediaTypes, Music, Sources, Status


class MusicModelTests(TestCase):
    """Music storage uses the existing generic media contracts."""

    def setUp(self):
        self.user = get_user_model().objects.create_user(username="listener")
        self.item = Item.objects.create(
            media_id="3bd76d40-7f0e-36b7-9348-91a33afee20e",
            source=Sources.MUSICBRAINZ.value,
            media_type=MediaTypes.MUSIC.value,
            title="Year Zero",
            image="https://example.com/year-zero.jpg",
        )

    def test_music_creation_history_and_diary(self):
        music = Music.objects.create(
            item=self.item,
            user=self.user,
            status=Status.PLANNING.value,
        )
        diary = DiaryEntry.objects.create(
            item=self.item,
            user=self.user,
            consumed_at=timezone.now(),
        )

        self.assertEqual(music.item, self.item)
        self.assertEqual(music.history.count(), 1)
        self.assertEqual(music.history.first().__class__.__name__, "HistoricalMusic")
        self.assertEqual(diary.item.media_type, MediaTypes.MUSIC.value)

    def test_music_item_identity_is_unique(self):
        with self.assertRaises(IntegrityError), transaction.atomic():
            Item.objects.create(
                media_id=self.item.media_id,
                source=self.item.source,
                media_type=self.item.media_type,
                title="Duplicate",
                image="https://example.com/duplicate.jpg",
            )
    def test_music_obeys_item_database_constraints(self):
        with self.assertRaises(IntegrityError), transaction.atomic():
            Item.objects.create(
                media_id="invalid-source",
                source="invalid",
                media_type=MediaTypes.MUSIC.value,
                title="Invalid source",
                image="https://example.com/invalid.jpg",
            )

        with self.assertRaises(IntegrityError), transaction.atomic():
            Item.objects.create(
                media_id="invalid-type",
                source=Sources.MUSICBRAINZ.value,
                media_type="invalid",
                title="Invalid type",
                image="https://example.com/invalid.jpg",
            )

        with self.assertRaises(IntegrityError), transaction.atomic():
            Item.objects.create(
                media_id="music-with-season",
                source=Sources.MUSICBRAINZ.value,
                media_type=MediaTypes.MUSIC.value,
                title="Invalid season",
                image="https://example.com/invalid.jpg",
                season_number=1,
            )
