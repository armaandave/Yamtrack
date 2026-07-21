from datetime import timedelta
from io import StringIO
from unittest.mock import patch

from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase
from django.utils import timezone

from app.models import ExternalRating, Item, MediaTypes, Sources


class BackfillExternalRatingsCommandTests(TestCase):
    def setUp(self):
        self.now = timezone.now()
        self.movie = Item.objects.create(
            media_id="1",
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            title="Movie",
        )
        self.anime = Item.objects.create(
            media_id="2",
            source=Sources.MAL.value,
            media_type=MediaTypes.ANIME.value,
            title="Anime",
        )
        self.game = Item.objects.create(
            media_id="3",
            source=Sources.IGDB.value,
            media_type=MediaTypes.GAME.value,
            title="Game",
        )
        Item.objects.create(
            media_id=Item.generate_manual_id(),
            source=Sources.MANUAL.value,
            media_type=MediaTypes.MOVIE.value,
            title="Manual",
        )
        self._rating(self.movie, "imdb", "available", value="8.5", maximum=10)
        self._rating(self.movie, "letterboxd", "unavailable", maximum=5)
        self._rating(self.movie, "tomatoes", "failed", maximum=100)
        self._rating(self.anime, "mal", "available", value="8.7", maximum=10)
        self._rating(
            self.game,
            "igdb",
            "available",
            value="90",
            maximum=100,
            attempted_at=self.now - timedelta(hours=25),
        )

    def _rating(
        self,
        item,
        source,
        status,
        *,
        value=None,
        maximum,
        attempted_at=None,
    ):
        attempted_at = attempted_at or self.now
        return ExternalRating.objects.create(
            item=item,
            rating_source=source,
            value=value,
            max_value=maximum,
            status=status,
            last_attempted_at=attempted_at,
            last_success_at=attempted_at if value is not None else None,
        )

    @patch("app.external_ratings.refresh_external_ratings")
    @patch("app.providers.services.get_media_metadata")
    @patch("app.providers.mdblist.get_media_ratings")
    @patch("app.management.commands.backfill_external_ratings.enqueue_external_rating_batches")
    def test_dry_run_reports_pair_and_item_counts_without_work(
        self,
        enqueue_mock,
        mdblist_mock,
        metadata_mock,
        refresh_mock,
    ):
        stdout = StringIO()

        with self.assertNumQueries(2):
            call_command(
                "backfill_external_ratings",
                dry_run=True,
                batch_size=2,
                stdout=stdout,
            )

        self.assertIn("Eligible item/source pairs: 7", stdout.getvalue())
        self.assertIn("Already fresh terminal pairs: 3", stdout.getvalue())
        self.assertIn("Pending/missing pairs: 4", stdout.getvalue())
        self.assertIn("Unavailable rows: 1", stdout.getvalue())
        self.assertIn("Failed rows: 1", stdout.getvalue())
        self.assertIn("Eligible Items: 3", stdout.getvalue())
        self.assertIn("Pending Items: 2", stdout.getvalue())
        self.assertIn("Selected Items: 2", stdout.getvalue())
        self.assertIn("Batches to queue: 1", stdout.getvalue())
        self.assertIn("Dry run: no tasks queued", stdout.getvalue())
        enqueue_mock.assert_not_called()
        mdblist_mock.assert_not_called()
        metadata_mock.assert_not_called()
        refresh_mock.assert_not_called()

    @patch("app.management.commands.backfill_external_ratings.enqueue_external_rating_batches")
    def test_source_media_and_item_scopes_are_combined(self, enqueue_mock):
        stdout = StringIO()

        call_command(
            "backfill_external_ratings",
            rating_sources=["tmdb"],
            media_types=[MediaTypes.MOVIE.value],
            item_sources=[Sources.TMDB.value],
            stdout=stdout,
        )

        self.assertIn("Eligible item/source pairs: 1", stdout.getvalue())
        self.assertIn("Pending/missing pairs: 1", stdout.getvalue())
        enqueue_mock.assert_called_once_with(
            [self.movie.pk],
            rating_sources=["tmdb"],
            force=False,
            batch_size=100,
        )

    @patch("app.management.commands.backfill_external_ratings.enqueue_external_rating_batches")
    def test_fresh_unavailable_skips_and_failed_retries(self, enqueue_mock):
        call_command(
            "backfill_external_ratings",
            rating_sources=["letterboxd"],
            stdout=StringIO(),
        )
        enqueue_mock.assert_not_called()

        call_command(
            "backfill_external_ratings",
            rating_sources=["tomatoes"],
            stdout=StringIO(),
        )
        enqueue_mock.assert_called_once_with(
            [self.movie.pk],
            rating_sources=["tomatoes"],
            force=False,
            batch_size=100,
        )

    @patch("app.management.commands.backfill_external_ratings.enqueue_external_rating_batches")
    def test_rerun_resumes_after_completed_work(self, enqueue_mock):
        call_command(
            "backfill_external_ratings",
            rating_sources=["tomatoes"],
            stdout=StringIO(),
        )
        rating = self.movie.external_ratings.get(rating_source="tomatoes")
        rating.status = ExternalRating.Status.AVAILABLE
        rating.value = 80
        rating.last_attempted_at = timezone.now()
        rating.last_success_at = rating.last_attempted_at
        rating.save()

        call_command(
            "backfill_external_ratings",
            rating_sources=["tomatoes"],
            stdout=StringIO(),
        )

        self.assertEqual(enqueue_mock.call_count, 1)

    @patch("app.management.commands.backfill_external_ratings.enqueue_external_rating_batches")
    def test_force_limit_and_stable_item_order(self, enqueue_mock):
        stdout = StringIO()

        call_command(
            "backfill_external_ratings",
            force=True,
            limit=2,
            batch_size=1,
            stdout=stdout,
        )

        self.assertIn("Selected Items: 2", stdout.getvalue())
        self.assertIn("Batches to queue: 2", stdout.getvalue())
        enqueue_mock.assert_called_once_with(
            [self.movie.pk, self.anime.pk],
            rating_sources=None,
            force=True,
            batch_size=1,
        )

    @patch("app.management.commands.backfill_external_ratings.enqueue_external_rating_batches")
    def test_limit_applies_to_pending_items_and_advances_on_rerun(self, enqueue_mock):
        options = {
            "rating_sources": ["tmdb", "igdb"],
            "limit": 1,
            "stdout": StringIO(),
        }

        call_command("backfill_external_ratings", **options)
        self.assertEqual(enqueue_mock.call_args.args[0], [self.movie.pk])

        self._rating(
            self.movie,
            "tmdb",
            "available",
            value="7.5",
            maximum=10,
        )
        enqueue_mock.reset_mock()
        options["stdout"] = StringIO()
        call_command("backfill_external_ratings", **options)

        self.assertEqual(enqueue_mock.call_args.args[0], [self.game.pk])

    def test_invalid_options_are_rejected(self):
        cases = (
            ({"rating_sources": ["goodreads"]}, "Unknown rating source"),
            ({"media_types": ["podcast"]}, "Unknown media type"),
            ({"item_sources": ["goodreads"]}, "Unknown item source"),
            ({"batch_size": 0}, "batch-size must be between 1 and 100"),
            ({"batch_size": 101}, "batch-size must be between 1 and 100"),
            ({"limit": 0}, "limit must be a positive integer"),
        )
        for options, message in cases:
            with self.subTest(options=options), self.assertRaisesMessage(CommandError, message):
                call_command("backfill_external_ratings", stdout=StringIO(), **options)

    @patch("app.management.commands.backfill_external_ratings.enqueue_external_rating_batches")
    def test_zero_eligible_records_succeeds_without_queueing(self, enqueue_mock):
        stdout = StringIO()

        call_command(
            "backfill_external_ratings",
            item_sources=[Sources.MANUAL.value],
            stdout=stdout,
        )

        self.assertIn("Eligible item/source pairs: 0", stdout.getvalue())
        self.assertIn("Selected Items: 0", stdout.getvalue())
        self.assertIn("No external-rating work to queue", stdout.getvalue())
        enqueue_mock.assert_not_called()
