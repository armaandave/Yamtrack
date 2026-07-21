from datetime import timedelta
from decimal import Decimal

from django.db import IntegrityError, transaction
from django.test import TestCase
from django.utils import timezone

from app.models import ExternalRating, Item, MediaTypes, Sources


class ExternalRatingModelTests(TestCase):
    def setUp(self):
        self.item = Item.objects.create(
            media_id="1",
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            title="Test Movie",
            image="https://example.com/movie.jpg",
        )
        self.now = timezone.now()

    def test_available_and_unavailable_rows_are_valid(self):
        available = ExternalRating(
            item=self.item,
            rating_source="imdb",
            value=Decimal("8.5000"),
            max_value=Decimal("10.0000"),
            vote_count=123,
            canonical_url="https://www.imdb.com/title/tt1/",
            status=ExternalRating.Status.AVAILABLE,
            last_attempted_at=self.now,
            last_success_at=self.now,
        )
        available.full_clean()
        available.save()

        unavailable = ExternalRating(
            item=self.item,
            rating_source="letterboxd",
            status=ExternalRating.Status.UNAVAILABLE,
            last_attempted_at=self.now,
        )
        unavailable.full_clean()
        unavailable.save()

        self.assertIsNone(unavailable.value)
        self.assertIsNone(unavailable.last_success_at)

    def test_item_and_rating_source_are_unique(self):
        ExternalRating.objects.create(
            item=self.item,
            rating_source="imdb",
            status=ExternalRating.Status.UNAVAILABLE,
            last_attempted_at=self.now,
        )

        with self.assertRaises(IntegrityError), transaction.atomic():
            ExternalRating.objects.create(
                item=self.item,
                rating_source="imdb",
                status=ExternalRating.Status.UNAVAILABLE,
                last_attempted_at=self.now,
            )

    def test_database_constraints_reject_invalid_rows(self):
        invalid_rows = [
            {
                "rating_source": "negative",
                "status": ExternalRating.Status.FAILED,
                "value": Decimal("-1"),
                "max_value": Decimal("10"),
                "last_success_at": self.now,
            },
            {
                "rating_source": "zero-max",
                "status": ExternalRating.Status.FAILED,
                "max_value": Decimal("0"),
            },
            {
                "rating_source": "over-scale",
                "status": ExternalRating.Status.FAILED,
                "value": Decimal("11"),
                "max_value": Decimal("10"),
                "last_success_at": self.now,
            },
            {
                "rating_source": "invalid-status",
                "status": "invalid",
            },
            {
                "rating_source": "available-without-value",
                "status": ExternalRating.Status.AVAILABLE,
            },
            {
                "rating_source": "available-without-max",
                "status": ExternalRating.Status.AVAILABLE,
                "value": Decimal("8"),
                "last_success_at": self.now,
            },
            {
                "rating_source": "available-without-success",
                "status": ExternalRating.Status.AVAILABLE,
                "value": Decimal("8"),
                "max_value": Decimal("10"),
            },
        ]

        for values in invalid_rows:
            with self.subTest(values["rating_source"]):
                with self.assertRaises(IntegrityError), transaction.atomic():
                    ExternalRating.objects.create(
                        item=self.item,
                        last_attempted_at=self.now,
                        **values,
                    )

    def test_ratings_follow_exact_episode_identity(self):
        episodes = [
            Item.objects.create(
                media_id="100",
                source=Sources.TMDB.value,
                media_type=MediaTypes.EPISODE.value,
                title=f"Episode {episode_number}",
                image="https://example.com/episode.jpg",
                season_number=1,
                episode_number=episode_number,
            )
            for episode_number in (1, 2)
        ]
        for episode, value in zip(episodes, (Decimal("7.5"), Decimal("9.0")), strict=True):
            ExternalRating.objects.create(
                item=episode,
                rating_source="imdb",
                value=value,
                max_value=Decimal("10"),
                status=ExternalRating.Status.AVAILABLE,
                last_attempted_at=self.now,
                last_success_at=self.now,
            )

        self.assertEqual(episodes[0].external_ratings.get().value, Decimal("7.5"))
        self.assertEqual(episodes[1].external_ratings.get().value, Decimal("9.0"))

    def test_failed_attempt_preserves_last_successful_value(self):
        rating = ExternalRating.objects.create(
            item=self.item,
            rating_source="imdb",
            value=Decimal("8.5"),
            max_value=Decimal("10"),
            vote_count=123,
            canonical_url="https://www.imdb.com/title/tt1/",
            status=ExternalRating.Status.AVAILABLE,
            last_attempted_at=self.now,
            last_success_at=self.now,
        )
        later = self.now + timedelta(hours=1)

        rating.status = ExternalRating.Status.FAILED
        rating.last_attempted_at = later
        rating.last_error = "Provider timeout"
        rating.full_clean()
        rating.save()
        rating.refresh_from_db()

        self.assertEqual(rating.value, Decimal("8.5"))
        self.assertEqual(rating.max_value, Decimal("10"))
        self.assertEqual(rating.vote_count, 123)
        self.assertEqual(rating.canonical_url, "https://www.imdb.com/title/tt1/")
        self.assertEqual(rating.last_success_at, self.now)
        self.assertEqual(rating.last_attempted_at, later)
        self.assertEqual(rating.status, ExternalRating.Status.FAILED)
        self.assertEqual(rating.last_error, "Provider timeout")
