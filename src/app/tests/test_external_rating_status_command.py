from datetime import timedelta
from io import StringIO

from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone

from app.models import ExternalRating, Item, MediaTypes, Sources


class ExternalRatingStatusCommandTests(TestCase):
    def setUp(self):
        self.now = timezone.now()
        self.movie = Item.objects.create(
            media_id="status-movie",
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            title="Status Movie",
        )

    def _rating(self, source, status, attempted_at, value=None):
        return ExternalRating.objects.create(
            item=self.movie,
            rating_source=source,
            value=value,
            max_value=10 if source != "unregistered-source" else 5,
            status=status,
            last_attempted_at=attempted_at,
            last_success_at=attempted_at if value is not None else None,
        )

    def test_reports_status_and_registry_freshness_groups(self):
        self._rating("imdb", ExternalRating.Status.AVAILABLE, self.now, "8")
        self._rating(
            "tmdb",
            ExternalRating.Status.UNAVAILABLE,
            self.now - timedelta(days=2),
        )
        self._rating("letterboxd", ExternalRating.Status.FAILED, self.now)
        self._rating("unregistered-source", ExternalRating.Status.UNAVAILABLE, self.now)

        output = StringIO()
        call_command("external_rating_status", stdout=output)

        report = output.getvalue()
        self.assertIn("imdb\tmovie\tavailable\tfresh\t1", report)
        self.assertIn("tmdb\tmovie\tunavailable\tstale\t1", report)
        self.assertIn("letterboxd\tmovie\tfailed\tstale\t1", report)
        self.assertIn(
            "unregistered-source\tmovie\tunavailable\tunregistered\t1",
            report,
        )
        self.assertIn("Total rows: 4", report)

    def test_filters_with_one_database_query(self):
        self._rating("imdb", ExternalRating.Status.AVAILABLE, self.now, "8")
        self._rating("tmdb", ExternalRating.Status.UNAVAILABLE, self.now)

        output = StringIO()
        with self.assertNumQueries(1):
            call_command(
                "external_rating_status",
                rating_sources=["imdb"],
                media_types=[MediaTypes.MOVIE.value],
                item_sources=[Sources.TMDB.value],
                stdout=output,
            )

        self.assertIn("imdb\tmovie\tavailable\tfresh\t1", output.getvalue())
        self.assertNotIn("tmdb\tmovie", output.getvalue())
        self.assertIn("Total rows: 1", output.getvalue())
