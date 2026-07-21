"""Queue resumable external-rating backfill work for known Items."""

from math import ceil

from django.core.management.base import BaseCommand, CommandError
from django.db.models import Prefetch, Q
from django.utils import timezone

from app.external_ratings import (
    RATING_SOURCES,
    eligible_rating_sources,
    rating_sources_needing_refresh,
)
from app.models import ExternalRating, Item, MediaTypes, Sources
from app.tasks import EXTERNAL_RATING_BATCH_SIZE, enqueue_external_rating_batches


class Command(BaseCommand):
    """Report and queue bounded backfill work without contacting providers."""

    help = "Report and queue resumable external-rating backfill work for known Items"

    def add_arguments(self, parser):
        parser.add_argument(
            "--rating-source",
            action="append",
            dest="rating_sources",
            choices=RATING_SOURCES,
            help="Limit to a registry source; repeat to include more than one.",
        )
        parser.add_argument(
            "--media-type",
            action="append",
            dest="media_types",
            choices=MediaTypes.values,
            help="Limit to an Item media type; repeat to include more than one.",
        )
        parser.add_argument(
            "--item-source",
            action="append",
            dest="item_sources",
            choices=Sources.values,
            help="Limit to an Item metadata source; repeat to include more than one.",
        )
        parser.add_argument(
            "--batch-size",
            type=int,
            default=EXTERNAL_RATING_BATCH_SIZE,
            help=f"Items per Celery batch (1-{EXTERNAL_RATING_BATCH_SIZE}).",
        )
        parser.add_argument("--limit", type=int, help="Maximum pending Items to queue.")
        parser.add_argument(
            "--force",
            action="store_true",
            help="Queue fresh eligible Items too.",
        )
        parser.add_argument(
            "--dry-run",
            action="store_true",
            help="Print counts without queueing tasks.",
        )

    def handle(self, *args, **options):  # noqa: ARG002
        rating_sources = self._validate_values(
            options["rating_sources"],
            RATING_SOURCES,
            "rating source",
        )
        media_types = self._validate_values(
            options["media_types"],
            MediaTypes.values,
            "media type",
        )
        item_sources = self._validate_values(
            options["item_sources"],
            Sources.values,
            "item source",
        )
        batch_size = options["batch_size"]
        limit = options["limit"]
        if not 1 <= batch_size <= EXTERNAL_RATING_BATCH_SIZE:
            msg = f"batch-size must be between 1 and {EXTERNAL_RATING_BATCH_SIZE}"
            raise CommandError(msg)
        if limit is not None and limit < 1:
            raise CommandError("limit must be a positive integer")

        registry_sources = rating_sources or list(RATING_SOURCES)
        identity_filter = Q(pk__isnull=True)
        for source in registry_sources:
            definition = RATING_SOURCES[source]
            identity_filter |= Q(
                source__in=definition["item_sources"],
                media_type__in=definition["media_types"],
            )

        items = Item.objects.filter(identity_filter)
        if media_types:
            items = items.filter(media_type__in=media_types)
        if item_sources:
            items = items.filter(source__in=item_sources)
        items = items.order_by("pk").prefetch_related(
            Prefetch(
                "external_ratings",
                queryset=ExternalRating.objects.filter(
                    rating_source__in=registry_sources,
                ),
            ),
        )

        counts = {
            "eligible_pairs": 0,
            "fresh_pairs": 0,
            "pending_pairs": 0,
            "unavailable": 0,
            "failed": 0,
            "eligible_items": 0,
            "pending_items": 0,
        }
        selected_ids = []
        now = timezone.now()
        for item in items.iterator(chunk_size=500):
            sources = eligible_rating_sources(item, rating_sources)
            if not sources:
                continue
            counts["eligible_items"] += 1
            counts["eligible_pairs"] += len(sources)
            rows = {
                row.rating_source: row
                for row in item.external_ratings.all()
                if row.rating_source in sources
            }
            pending = set(
                rating_sources_needing_refresh(item, sources, now=now),
            )
            counts["pending_pairs"] += len(pending)
            counts["fresh_pairs"] += len(sources) - len(pending)
            counts["unavailable"] += sum(
                row.status == ExternalRating.Status.UNAVAILABLE
                for row in rows.values()
            )
            counts["failed"] += sum(
                row.status == ExternalRating.Status.FAILED
                for row in rows.values()
            )
            if pending:
                counts["pending_items"] += 1
            if (options["force"] or pending) and (
                limit is None or len(selected_ids) < limit
            ):
                selected_ids.append(item.pk)

        batches = ceil(len(selected_ids) / batch_size)
        report = (
            ("Eligible item/source pairs", counts["eligible_pairs"]),
            ("Already fresh terminal pairs", counts["fresh_pairs"]),
            ("Pending/missing pairs", counts["pending_pairs"]),
            ("Unavailable rows", counts["unavailable"]),
            ("Failed rows", counts["failed"]),
            ("Eligible Items", counts["eligible_items"]),
            ("Pending Items", counts["pending_items"]),
            ("Selected Items", len(selected_ids)),
            ("Batches to queue", batches),
        )
        for label, value in report:
            self.stdout.write(f"{label}: {value}")

        if options["dry_run"]:
            self.stdout.write("Dry run: no tasks queued")
            return
        if not selected_ids:
            self.stdout.write("No external-rating work to queue")
            return

        enqueue_external_rating_batches(
            selected_ids,
            rating_sources=rating_sources,
            force=options["force"],
            batch_size=batch_size,
        )
        self.stdout.write(self.style.SUCCESS(f"Queued {len(selected_ids)} Items in {batches} batches"))

    @staticmethod
    def _validate_values(values, valid_values, label):
        if values is None:
            return None
        values = list(dict.fromkeys(values))
        invalid = [value for value in values if value not in valid_values]
        if invalid:
            raise CommandError(f"Unknown {label}: {invalid[0]}")
        return values
