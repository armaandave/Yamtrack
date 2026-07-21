"""Report persisted external-rating health without queueing work."""

from django.core.management.base import BaseCommand
from django.db.models import Case, CharField, Count, Q, Value, When
from django.utils import timezone

from app.external_ratings import RATING_SOURCES
from app.models import ExternalRating, MediaTypes, Sources


def freshness_expression(now):
    """Classify rows using the registry's per-source freshness policy."""
    terminal = [
        ExternalRating.Status.AVAILABLE,
        ExternalRating.Status.UNAVAILABLE,
    ]
    fresh = [
        When(
            rating_source=source,
            status__in=terminal,
            last_attempted_at__gte=now - definition["fresh_for"],
            then=Value("fresh"),
        )
        for source, definition in RATING_SOURCES.items()
    ]
    return Case(
        *fresh,
        When(rating_source__in=RATING_SOURCES, then=Value("stale")),
        default=Value("unregistered"),
        output_field=CharField(),
    )


class Command(BaseCommand):
    """Print deterministic grouped counts from persisted rows only."""

    help = "Report external-rating counts by source, media type, status, and freshness"

    def add_arguments(self, parser):
        parser.add_argument(
            "--rating-source",
            action="append",
            dest="rating_sources",
            choices=RATING_SOURCES,
        )
        parser.add_argument(
            "--media-type",
            action="append",
            dest="media_types",
            choices=MediaTypes.values,
        )
        parser.add_argument(
            "--item-source",
            action="append",
            dest="item_sources",
            choices=Sources.values,
        )

    def handle(self, *args, **options):  # noqa: ARG002
        now = timezone.now()
        rows = ExternalRating.objects.all()
        for field, values in (
            ("rating_source__in", options["rating_sources"]),
            ("item__media_type__in", options["media_types"]),
            ("item__source__in", options["item_sources"]),
        ):
            if values:
                rows = rows.filter(**{field: values})

        grouped = (
            rows.annotate(freshness=freshness_expression(now))
            .values(
                "rating_source",
                "item__media_type",
                "status",
                "freshness",
            )
            .annotate(count=Count("id"))
            .order_by(
                "rating_source",
                "item__media_type",
                "status",
                "freshness",
            )
        )
        self.stdout.write(f"As of: {now.isoformat()}")
        self.stdout.write("rating_source\tmedia_type\tstatus\tfreshness\tcount")
        total = 0
        for row in grouped:
            total += row["count"]
            self.stdout.write(
                "\t".join(
                    str(value)
                    for value in (
                        row["rating_source"],
                        row["item__media_type"],
                        row["status"],
                        row["freshness"],
                        row["count"],
                    )
                ),
            )
        self.stdout.write(f"Total rows: {total}")
