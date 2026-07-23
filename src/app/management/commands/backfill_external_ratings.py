"""Queue resumable external-rating backfill work for known Items."""

import json
import time
from collections import Counter
from itertools import batched
from math import ceil

from celery.exceptions import TimeoutError as CeleryTimeoutError
from celery.result import AsyncResult
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
from config.celery import app as celery_app


class Command(BaseCommand):
    """Report and queue bounded backfill work without provider calls here."""

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
        parser.add_argument("--limit", type=int, help="Maximum pending Items to select per wave.")
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
        parser.add_argument(
            "--coverage-only",
            action="store_true",
            help="Select only missing or failed pairs; stale terminal rows count as covered.",
        )
        parser.add_argument(
            "--drain",
            action="store_true",
            help="Process sequential batches until coverage is complete or safely paused.",
        )
        parser.add_argument(
            "--json",
            action="store_true",
            dest="json_output",
            help="Emit newline-delimited JSON events.",
        )
        parser.add_argument(
            "--max-runtime-seconds",
            type=int,
            default=4 * 60 * 60,
            help="Drain runtime ceiling checked between completed batches.",
        )
        parser.add_argument(
            "--wait-timeout-seconds",
            type=int,
            default=30 * 60,
            help="Maximum wait for one exact Celery batch result.",
        )
        parser.add_argument(
            "--max-items",
            type=int,
            help="Optional total item ceiling for a drain run; used by canaries.",
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
        self._validate_options(
            options,
            rating_sources=rating_sources,
            media_types=media_types,
            item_sources=item_sources,
        )

        common = {
            "rating_sources": rating_sources,
            "media_types": media_types,
            "item_sources": item_sources,
            "coverage_only": options["coverage_only"],
        }
        if options["drain"]:
            self._drain(options, **common)
            return

        work = self._scan(limit=options["limit"], force=options["force"], **common)
        self._report(
            work,
            json_output=options["json_output"],
            batch_size=options["batch_size"],
        )
        if options["dry_run"]:
            self._write("Dry run: no tasks queued", options["json_output"], event="dry_run")
            return
        if not work["selected_ids"]:
            self._write(
                "No external-rating work to queue",
                options["json_output"],
                event="complete",
                status="complete",
            )
            return

        queued = enqueue_external_rating_batches(
            work["selected_ids"],
            rating_sources=rating_sources,
            force=options["force"],
            batch_size=options["batch_size"],
        )
        self._write(
            f"Queued {queued['items']} Items in {queued['batches']} batches",
            options["json_output"],
            event="queued",
            status="queued",
            items=queued["items"],
            batches=queued["batches"],
            task_ids=queued["task_ids"],
        )

    def _drain(
        self,
        options,
        *,
        rating_sources,
        media_types,
        item_sources,
        coverage_only,
    ):
        started = time.monotonic()
        item_totals = Counter()
        outcome_totals = Counter()
        batches_completed = 0
        items_requested = 0
        initial = self._scan(
            limit=options["limit"],
            force=False,
            rating_sources=rating_sources,
            media_types=media_types,
            item_sources=item_sources,
            coverage_only=coverage_only,
        )
        starting_pending_pairs = initial["pending_pairs"]
        self._report(
            initial,
            json_output=options["json_output"],
            batch_size=options["batch_size"],
        )
        current = initial

        while current["pending_pairs"]:
            if time.monotonic() - started >= options["max_runtime_seconds"]:
                self._finish_drain(
                    "paused",
                    "max_runtime",
                    current,
                    started,
                    starting_pending_pairs,
                    batches_completed,
                    items_requested,
                    item_totals,
                    outcome_totals,
                    options["json_output"],
                )
                return

            selected_ids = current["selected_ids"]
            if options["max_items"] is not None:
                remaining = options["max_items"] - items_requested
                if remaining <= 0:
                    self._finish_drain(
                        "paused",
                        "item_limit",
                        current,
                        started,
                        starting_pending_pairs,
                        batches_completed,
                        items_requested,
                        item_totals,
                        outcome_totals,
                        options["json_output"],
                    )
                    return
                selected_ids = selected_ids[:remaining]
            if not selected_ids:
                self._fail_drain(
                    "Pending work exists but no Items were selected",
                    current,
                    started,
                    starting_pending_pairs,
                    batches_completed,
                    items_requested,
                    item_totals,
                    outcome_totals,
                    options["json_output"],
                )

            pending_before = current["pending_pairs"]
            for item_batch in batched(selected_ids, options["batch_size"]):
                batch_ids = list(item_batch)
                queued = enqueue_external_rating_batches(
                    batch_ids,
                    rating_sources=rating_sources,
                    force=False,
                    batch_size=options["batch_size"],
                )
                task_ids = queued.get("task_ids") or []
                if (
                    queued.get("items") != len(batch_ids)
                    or queued.get("batches") != 1
                    or len(task_ids) != 1
                ):
                    self._fail_drain(
                        "Sequential drain expected exactly one Celery task",
                        current,
                        started,
                        starting_pending_pairs,
                        batches_completed,
                        items_requested,
                        item_totals,
                        outcome_totals,
                        options["json_output"],
                    )

                try:
                    result = self._wait_for_batch(
                        task_ids[0],
                        timeout=options["wait_timeout_seconds"],
                    )
                    self._validate_batch_result(
                        result,
                        expected_requested=len(batch_ids),
                    )
                except CommandError as error:
                    self._fail_drain(
                        str(error),
                        current,
                        started,
                        starting_pending_pairs,
                        batches_completed,
                        items_requested,
                        item_totals,
                        outcome_totals,
                        options["json_output"],
                    )
                batches_completed += 1
                items_requested += result["requested"]
                item_totals.update(
                    {
                        key: result.get(key, 0)
                        for key in (
                            "refreshed",
                            "fresh",
                            "skipped",
                            "deduplicated",
                            "partial",
                            "failed",
                            "retrying",
                        )
                    },
                )
                outcome_totals.update(result["outcomes"])
                self._write(
                    f"Completed batch {batches_completed}",
                    options["json_output"],
                    event="batch_complete",
                    batch=batches_completed,
                    task_id=task_ids[0],
                    result=result,
                )
                if (
                    result["failed"]
                    or result["partial"]
                    or result["retrying"]
                    or result["outcomes"]["failed"]
                ):
                    self._fail_drain(
                        "External-rating batch reported failed or retrying work",
                        current,
                        started,
                        starting_pending_pairs,
                        batches_completed,
                        items_requested,
                        item_totals,
                        outcome_totals,
                        options["json_output"],
                    )
                if (
                    time.monotonic() - started >= options["max_runtime_seconds"]
                    or (
                        options["max_items"] is not None
                        and items_requested >= options["max_items"]
                    )
                ):
                    break

            current = self._scan(
                limit=options["limit"],
                force=False,
                rating_sources=rating_sources,
                media_types=media_types,
                item_sources=item_sources,
                coverage_only=coverage_only,
            )
            if current["pending_pairs"] >= pending_before:
                self._fail_drain(
                    "External-rating drain made no coverage progress",
                    current,
                    started,
                    starting_pending_pairs,
                    batches_completed,
                    items_requested,
                    item_totals,
                    outcome_totals,
                    options["json_output"],
                )
            if (
                options["max_items"] is not None
                and items_requested >= options["max_items"]
                and current["pending_pairs"]
            ):
                self._finish_drain(
                    "paused",
                    "item_limit",
                    current,
                    started,
                    starting_pending_pairs,
                    batches_completed,
                    items_requested,
                    item_totals,
                    outcome_totals,
                    options["json_output"],
                )
                return

        self._finish_drain(
            "complete",
            "coverage_complete",
            current,
            started,
            starting_pending_pairs,
            batches_completed,
            items_requested,
            item_totals,
            outcome_totals,
            options["json_output"],
        )

    def _scan(
        self,
        *,
        limit,
        force,
        rating_sources,
        media_types,
        item_sources,
        coverage_only,
    ):
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

        counts = Counter()
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
            if coverage_only:
                pending = {
                    source
                    for source in sources
                    if (row := rows.get(source)) is None
                    or row.status == ExternalRating.Status.FAILED
                }
            else:
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
            if (force or pending) and (
                limit is None or len(selected_ids) < limit
            ):
                selected_ids.append(item.pk)

        return {
            **{
                key: counts[key]
                for key in (
                    "eligible_pairs",
                    "fresh_pairs",
                    "pending_pairs",
                    "unavailable",
                    "failed",
                    "eligible_items",
                    "pending_items",
                )
            },
            "selected_ids": selected_ids,
            "selected_items": len(selected_ids),
        }

    def _report(self, work, *, json_output, batch_size):
        report = (
            ("Eligible item/source pairs", "eligible_pairs"),
            ("Already fresh terminal pairs", "fresh_pairs"),
            ("Pending/missing pairs", "pending_pairs"),
            ("Unavailable rows", "unavailable"),
            ("Failed rows", "failed"),
            ("Eligible Items", "eligible_items"),
            ("Pending Items", "pending_items"),
            ("Selected Items", "selected_items"),
        )
        if json_output:
            self._write(
                "External-rating inventory",
                True,
                event="inventory",
                **{key: work[key] for _, key in report},
                batches_to_queue=ceil(work["selected_items"] / batch_size),
            )
            return
        for label, key in report:
            self.stdout.write(f"{label}: {work[key]}")
        self.stdout.write(
            f"Batches to queue: {ceil(work['selected_items'] / batch_size)}",
        )

    def _wait_for_batch(self, task_id, *, timeout):
        try:
            return AsyncResult(task_id, app=celery_app).get(
                timeout=timeout,
                propagate=True,
            )
        except CeleryTimeoutError as error:
            msg = f"Timed out waiting for external-rating batch {task_id}"
            raise CommandError(msg) from error
        except Exception as error:
            msg = f"External-rating batch {task_id} failed: {type(error).__name__}"
            raise CommandError(msg) from error

    @staticmethod
    def _validate_batch_result(result, *, expected_requested):
        item_keys = {
            "requested",
            "refreshed",
            "fresh",
            "skipped",
            "deduplicated",
            "partial",
            "failed",
            "retrying",
            "outcomes",
        }
        outcome_keys = {
            "attempted",
            "available",
            "unavailable",
            "failed",
            "skipped_fresh",
            "preserved_stale",
        }
        if (
            not isinstance(result, dict)
            or not item_keys.issubset(result)
            or not isinstance(result["outcomes"], dict)
            or not outcome_keys.issubset(result["outcomes"])
            or any(
                not isinstance(result[key], int) or result[key] < 0
                for key in item_keys - {"outcomes"}
            )
            or any(
                not isinstance(result["outcomes"][key], int)
                or result["outcomes"][key] < 0
                for key in outcome_keys
            )
            or result["requested"] != expected_requested
        ):
            raise CommandError("External-rating batch returned a malformed result")

    def _finish_drain(
        self,
        status,
        reason,
        current,
        started,
        starting_pending_pairs,
        batches_completed,
        items_requested,
        item_totals,
        outcome_totals,
        json_output,
    ):
        elapsed = round(time.monotonic() - started, 3)
        eligible_pairs = current["eligible_pairs"]
        payload = {
            "status": status,
            "reason": reason,
            "eligible_pairs": eligible_pairs,
            "starting_pending_pairs": starting_pending_pairs,
            "ending_pending_pairs": current["pending_pairs"],
            "starting_covered_pairs": max(
                eligible_pairs - starting_pending_pairs,
                0,
            ),
            "ending_covered_pairs": eligible_pairs - current["pending_pairs"],
            "batches_completed": batches_completed,
            "items_requested": items_requested,
            "refreshed_items": item_totals["refreshed"],
            "failed_items": item_totals["failed"] + item_totals["partial"],
            "retrying_items": item_totals["retrying"],
            "available": outcome_totals["available"],
            "unavailable": outcome_totals["unavailable"],
            "failed": outcome_totals["failed"],
            "elapsed_seconds": elapsed,
        }
        self._write(
            f"External-rating drain {status}: {reason}",
            json_output,
            event=status,
            **payload,
        )

    def _fail_drain(self, message, *summary_args):
        self._finish_drain("failed", message, *summary_args)
        raise CommandError(message)

    def _write(self, message, json_output, *, event, **payload):
        if json_output:
            self.stdout.write(
                json.dumps(
                    {"event": event, **payload},
                    sort_keys=True,
                ),
            )
        else:
            self.stdout.write(message)

    @staticmethod
    def _validate_options(
        options,
        *,
        rating_sources,
        media_types,
        item_sources,
    ):
        batch_size = options["batch_size"]
        if not 1 <= batch_size <= EXTERNAL_RATING_BATCH_SIZE:
            msg = f"batch-size must be between 1 and {EXTERNAL_RATING_BATCH_SIZE}"
            raise CommandError(msg)
        for option, label in (
            ("limit", "limit"),
            ("max_runtime_seconds", "max-runtime-seconds"),
            ("wait_timeout_seconds", "wait-timeout-seconds"),
            ("max_items", "max-items"),
        ):
            if options[option] is not None and options[option] < 1:
                raise CommandError(f"{label} must be a positive integer")
        if not options["drain"]:
            return
        if not all((rating_sources, media_types, item_sources)):
            raise CommandError(
                "drain requires explicit rating-source, media-type, and item-source filters",
            )
        if not options["coverage_only"]:
            raise CommandError("drain requires coverage-only")
        if options["limit"] is None:
            raise CommandError("drain requires a positive limit")
        if options["force"]:
            raise CommandError("drain cannot be combined with force")
        if options["dry_run"]:
            raise CommandError("drain cannot be combined with dry-run")

    @staticmethod
    def _validate_values(values, valid_values, label):
        if values is None:
            return None
        values = list(dict.fromkeys(values))
        invalid = [value for value in values if value not in valid_values]
        if invalid:
            raise CommandError(f"Unknown {label}: {invalid[0]}")
        return values
