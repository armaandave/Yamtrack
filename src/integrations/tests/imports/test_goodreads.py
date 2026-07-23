import csv
import io
import tempfile
from datetime import date
from decimal import Decimal
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, Mock, patch

import requests
from django.contrib.auth import get_user_model
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase
from django.utils import timezone
from django_celery_results.models import TaskResult
from rest_framework import status
from rest_framework.test import APIClient

from app.models import (
    Book,
    DiaryEntry,
    Item,
    MediaTypes,
    Movie,
    Sources,
    Status,
)
from app.providers import services
from integrations.imports import (
    goodreads,
)
from integrations import tasks

fixture_path = (
    Path(__file__).resolve().parent.parent / "fixtures" / "goodreads" / "minimal.csv"
)


def csv_payload(
    *,
    row_indexes=None,
    overrides=None,
    remove_columns=(),
    extra_columns=None,
    bom=False,
):
    """Return a deterministic variant of the sanitized Goodreads fixture."""
    with fixture_path.open(encoding="utf-8", newline="") as export:
        reader = csv.DictReader(export)
        fieldnames = list(reader.fieldnames or [])
        rows = list(reader)

    if row_indexes is not None:
        rows = [rows[index].copy() for index in row_indexes]

    remove_columns = set(remove_columns)
    fieldnames = [name for name in fieldnames if name not in remove_columns]
    extra_columns = extra_columns or {}
    fieldnames.extend(name for name in extra_columns if name not in fieldnames)

    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()
    for row in rows:
        normalized = {name: value for name, value in row.items() if name in fieldnames}
        normalized.update(overrides or {})
        normalized.update(extra_columns)
        writer.writerow(normalized)

    payload = output.getvalue().encode()
    return b"\xef\xbb\xbf" + payload if bom else payload


class FakeResolver:
    """Resolve fictional fixture titles without contacting book providers."""

    BOOKS = {
        "Atlas of Quiet Signals": ("hc-1001", 321),
        "The Tenth Character": ("hc-1002", 240),
        "The Mismatched Compass": ("hc-1003", 198),
        "Paused Between Pages": ("hc-1004", None),
        "The Deliberate Exit": ("hc-1005", 175),
        "An Unfamiliar Shelf": ("hc-1006", 110),
    }

    def resolve_rows(self, rows):
        resolved = {}
        for row in rows:
            media_id, total_pages = self.BOOKS[row.title]
            resolved[row.index] = {
                "media_id": media_id,
                "source": Sources.HARDCOVER.value,
                "title": row.title,
                "image": f"https://example.com/{media_id}.jpg",
                "max_progress": total_pages,
                "total_pages": total_pages,
            }
        return resolved


class GoodreadsParserTests(TestCase):
    """Test header-driven normalization of Goodreads export values."""

    def test_excel_wrapped_isbns_are_validated_and_normalized(self):
        rows = goodreads.parse_export(fixture_path.read_bytes())

        self.assertEqual(rows[0].isbn13, "9780306406157")
        self.assertEqual(rows[0].isbn10, "0306406152")
        self.assertEqual(rows[1].isbn10, "097522980X")
        self.assertEqual(rows[2].isbn13, "")
        self.assertEqual(rows[2].isbn10, "")
        self.assertEqual(rows[2].identifiers, [])

    def test_all_supported_shelf_aliases_map_to_statuses(self):
        cases = {
            "read": Status.COMPLETED.value,
            "currently-reading": Status.IN_PROGRESS.value,
            "to-read": Status.PLANNING.value,
            "paused": Status.PAUSED.value,
            "on-hold": Status.PAUSED.value,
            "dnf": Status.DROPPED.value,
            "did-not-finish": Status.DROPPED.value,
            "unfinished": Status.DROPPED.value,
            "abandoned": Status.DROPPED.value,
            "dropped": Status.DROPPED.value,
        }
        for shelf, expected in cases.items():
            with self.subTest(shelf=shelf):
                row = goodreads.parse_export(
                    csv_payload(
                        row_indexes=[0],
                        overrides={"Exclusive Shelf": shelf},
                    ),
                )[0]
                self.assertEqual(row.status, expected)
                self.assertFalse(row.status_was_fallback)

        fallback = goodreads.parse_export(
            csv_payload(
                row_indexes=[0],
                overrides={"Exclusive Shelf": "owned-only"},
            ),
        )[0]
        self.assertEqual(fallback.status, Status.PLANNING.value)
        self.assertTrue(fallback.status_was_fallback)

    def test_ratings_and_dates_handle_every_value_and_blanks(self):
        expected_ratings = {
            "0": None,
            "1": Decimal("2"),
            "2": Decimal("4"),
            "3": Decimal("6"),
            "4": Decimal("8"),
            "5": Decimal("10"),
        }
        for raw, expected in expected_ratings.items():
            with self.subTest(rating=raw):
                row = goodreads.parse_export(
                    csv_payload(
                        row_indexes=[0],
                        overrides={"My Rating": raw},
                    ),
                )[0]
                self.assertEqual(row.rating, expected)

        dated = goodreads.parse_export(fixture_path.read_bytes())[0]
        blank = goodreads.parse_export(fixture_path.read_bytes())[1]
        self.assertEqual(dated.date_read.date(), date(2025, 1, 3))
        self.assertEqual(dated.date_added.date(), date(2024, 12, 31))
        self.assertIsNone(blank.date_read)
        self.assertIsNone(blank.date_added)


class GoodreadsModernImportTests(TestCase):
    """Test modern Goodreads CSV semantics using only sanitized data."""

    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="modern-goodreads",
            password="password",
        )

    def _import(self, payload=None, mode="new", resolver=None):
        payload = fixture_path.read_bytes() if payload is None else payload
        resolver = FakeResolver() if resolver is None else resolver
        with patch("app.models.Item.fetch_releases"):
            with patch(
                "app.models.providers.services.get_media_metadata",
                return_value={"max_progress": 321},
            ):
                with patch("app.services.update_daily_statistics.delay"):
                    with patch("app.signals.update_daily_statistics.delay"):
                        return goodreads.GoodReadsImporter(
                            io.BytesIO(payload),
                            self.user,
                            mode,
                            resolver=resolver,
                        ).import_data()

    def test_current_23_column_export_accepts_bom_and_ignores_extra_headers(self):
        optional_columns = {
            "Private Notes",
            "Spoiler",
            "Bookshelves",
            "Bookshelves with positions",
            "Read Count",
            "Owned Copies",
            "Number of Pages",
        }
        payload = csv_payload(
            remove_columns=optional_columns,
            extra_columns={
                "Average Rating": "4.25",
                "Recommended For": "ignored legacy value",
            },
            bom=True,
        )

        rows = goodreads.parse_export(payload)

        self.assertEqual(len(rows), 6)
        self.assertEqual(rows[0].title, "Atlas of Quiet Signals")

    def test_full_import_maps_status_rating_dates_and_social_fields(self):
        counts, warnings = self._import()

        self.assertEqual(counts[MediaTypes.BOOK.value], 6)
        self.assertEqual(counts["diary"], 1)
        self.assertEqual(Book.objects.filter(user=self.user).count(), 6)

        expected = {
            "hc-1001": (Status.COMPLETED.value, Decimal("8")),
            "hc-1002": (Status.IN_PROGRESS.value, None),
            "hc-1003": (Status.PLANNING.value, Decimal("10")),
            "hc-1004": (Status.PAUSED.value, Decimal("6")),
            "hc-1005": (Status.DROPPED.value, Decimal("4")),
            "hc-1006": (Status.PLANNING.value, Decimal("2")),
        }
        for media_id, (expected_status, expected_score) in expected.items():
            book = Book.objects.get(user=self.user, item__media_id=media_id)
            self.assertEqual(book.status, expected_status)
            self.assertEqual(book.score, expected_score)

        completed = Book.objects.get(user=self.user, item__media_id="hc-1001")
        self.assertEqual(completed.progress, 321)
        self.assertEqual(completed.end_date.date(), date(2025, 1, 3))
        self.assertEqual(
            completed.history.order_by("-history_date").first().history_date.date(),
            date(2025, 1, 3),
        )
        self.assertIn("Keep this private.", completed.notes)
        self.assertIn("Read count: 2", completed.notes)
        self.assertIn("Undated reads: 1", completed.notes)

        entries = list(DiaryEntry.objects.filter(user=self.user, item=completed.item))
        self.assertEqual(len(entries), 1)
        entry = entries[0]
        self.assertEqual(entry.consumed_at.date(), date(2025, 1, 3))
        self.assertEqual(entry.rating, Decimal("8"))
        self.assertEqual(entry.review, "A precise, thoughtful read.")
        self.assertTrue(entry.contains_spoilers)
        self.assertTrue(entry.is_rewatch)
        self.assertEqual(
            sorted(tag.name for tag in entry.tags.all()),
            ["favorite", "migration"],
        )
        self.assertEqual(completed.completion_diary_entry, entry)

        current = Book.objects.get(user=self.user, item__media_id="hc-1002")
        self.assertIsNone(current.end_date)
        planning = Book.objects.get(user=self.user, item__media_id="hc-1003")
        self.assertIsNone(planning.start_date)
        self.assertEqual(
            planning.history.order_by("-history_date").first().history_date.date(),
            date(2025, 2, 2),
        )
        dropped = Book.objects.get(user=self.user, item__media_id="hc-1005")
        self.assertIsNone(dropped.end_date)

        self.assertIn("An Unfamiliar Shelf", warnings)
        self.assertIn("owned-only", warnings)

    def test_duplicate_rows_resolving_to_one_item_do_not_duplicate_state(self):
        payload = csv_payload(row_indexes=[0, 0])

        counts, _warnings = self._import(payload)

        self.assertEqual(counts[MediaTypes.BOOK.value], 1)
        self.assertEqual(Book.objects.filter(user=self.user).count(), 1)
        self.assertEqual(DiaryEntry.objects.filter(user=self.user).count(), 1)

    def test_imported_dates_drive_book_session_and_history_provenance(self):
        self._import()

        completed = Book.objects.get(user=self.user, item__media_id="hc-1001")
        completed_session = completed.reading_sessions.get(status=Status.COMPLETED.value)
        self.assertEqual(completed.end_date.date(), date(2025, 1, 3))
        self.assertEqual(completed_session.end_date.date(), date(2025, 1, 3))
        self.assertEqual(
            completed.history.order_by("-history_date").first().history_date.date(),
            date(2025, 1, 3),
        )

        planning = Book.objects.get(user=self.user, item__media_id="hc-1003")
        self.assertEqual(
            planning.history.order_by("-history_date").first().history_date.date(),
            date(2025, 2, 2),
        )

    def test_date_added_is_preserved_as_history_provenance(self):
        self._import()

        planning = Book.objects.get(user=self.user, item__media_id="hc-1003")
        self.assertEqual(
            planning.history.order_by("-history_date").first().history_date.date(),
            date(2025, 2, 2),
        )

    def test_review_without_completed_diary_is_not_silently_discarded(self):
        self._import()

        dropped = Book.objects.get(user=self.user, item__media_id="hc-1005")
        imported_review = DiaryEntry.objects.filter(
            user=self.user,
            item=dropped.item,
            review="Not for me.",
        ).exists()
        self.assertTrue(imported_review or "Not for me." in dropped.notes)

    def test_new_mode_is_idempotent_and_preserves_existing_tracking(self):
        self._import()
        Book.objects.filter(user=self.user, item__media_id="hc-1001").update(
            status=Status.PAUSED.value,
            notes="manual state",
            score=Decimal("1"),
        )

        self._import()
        self._import()

        book = Book.objects.get(user=self.user, item__media_id="hc-1001")
        self.assertEqual(book.status, Status.PAUSED.value)
        self.assertEqual(book.notes, "manual state")
        self.assertEqual(book.score, Decimal("1"))
        self.assertEqual(Book.objects.filter(user=self.user).count(), 6)
        self.assertEqual(DiaryEntry.objects.filter(user=self.user).count(), 1)

    def test_overwrite_removes_only_current_users_book_tracking_and_diary(self):
        other_user = get_user_model().objects.create_user(
            username="other-reader",
            password="password",
        )
        old_book_item = Item.objects.create(
            media_id="old-book",
            source=Sources.HARDCOVER.value,
            media_type=MediaTypes.BOOK.value,
            title="Old Book",
            image="https://example.com/old-book.jpg",
        )
        movie_item = Item.objects.create(
            media_id="movie",
            source=Sources.TMDB.value,
            media_type=MediaTypes.MOVIE.value,
            title="Movie",
            image="https://example.com/movie.jpg",
        )
        with patch("app.models.Item.fetch_releases"):
            with patch(
                "app.models.providers.services.get_media_metadata",
                return_value={"max_progress": 120},
            ):
                Book.objects.create(
                    user=self.user,
                    item=old_book_item,
                    status=Status.PLANNING.value,
                )
                Book.objects.create(
                    user=other_user,
                    item=old_book_item,
                    status=Status.PLANNING.value,
                )
                Movie.objects.create(
                    user=self.user,
                    item=movie_item,
                    status=Status.COMPLETED.value,
                )
        with patch("app.signals.update_daily_statistics.delay"):
            old_book_diary = DiaryEntry.objects.create(
                user=self.user,
                item=old_book_item,
                consumed_at=timezone.now(),
            )
            other_book_diary = DiaryEntry.objects.create(
                user=other_user,
                item=old_book_item,
                consumed_at=timezone.now(),
            )
            movie_diary = DiaryEntry.objects.create(
                user=self.user,
                item=movie_item,
                consumed_at=timezone.now(),
            )

        self._import(mode="overwrite")

        self.assertFalse(Book.objects.filter(user=self.user, item=old_book_item).exists())
        self.assertFalse(DiaryEntry.objects.filter(id=old_book_diary.id).exists())
        self.assertTrue(Book.objects.filter(user=other_user, item=old_book_item).exists())
        self.assertTrue(DiaryEntry.objects.filter(id=other_book_diary.id).exists())
        self.assertTrue(Movie.objects.filter(user=self.user, item=movie_item).exists())
        self.assertTrue(DiaryEntry.objects.filter(id=movie_diary.id).exists())

    def test_unresolved_rows_warn_with_title_and_goodreads_id(self):
        resolver = SimpleNamespace(resolve_rows=lambda rows: {})

        counts, warnings = self._import(resolver=resolver)

        self.assertEqual(counts, {})
        self.assertFalse(Book.objects.filter(user=self.user).exists())
        self.assertIn("Atlas of Quiet Signals", warnings)
        self.assertIn("Goodreads ID 1001", warnings)


class GoodreadsResolverTests(TestCase):
    """Test exact identifiers and conservative provider fallback behavior."""

    EXACT_HARDCOVER = {
        "media_id": "exact-hc",
        "source": Sources.HARDCOVER.value,
        "media_type": MediaTypes.BOOK.value,
        "title": "Atlas of Quiet Signals",
        "image": "https://example.com/exact-hc.jpg",
        "author_name": "Avery North",
        "matched_isbn": "9780306406157",
        "max_progress": 321,
        "total_pages": 321,
    }
    EXACT_OPENLIBRARY = {
        "media_id": "OL-EXACT",
        "source": Sources.OPENLIBRARY.value,
        "media_type": MediaTypes.BOOK.value,
        "title": "Atlas of Quiet Signals",
        "image": "https://example.com/exact-ol.jpg",
        "matched_isbn": "0306406152",
    }
    HARDCOVER_METADATA = {
        "media_id": "metadata-hc",
        "source": Sources.HARDCOVER.value,
        "media_type": MediaTypes.BOOK.value,
        "title": "Atlas of Quiet Signals",
        "image": "https://example.com/metadata-hc.jpg",
        "author_name": "Avery North",
        "first_publish_year": 2025,
    }
    OPENLIBRARY_METADATA = {
        "media_id": "metadata-ol",
        "source": Sources.OPENLIBRARY.value,
        "media_type": MediaTypes.BOOK.value,
        "title": "Atlas of Quiet Signals",
        "image": "https://example.com/metadata-ol.jpg",
        "author_name": ["Avery North"],
        "first_publish_year": 2025,
    }

    def _row(self, index=0):
        return goodreads.parse_export(fixture_path.read_bytes())[index]

    def _resolve(self, row):
        return goodreads.GoodreadsResolver().resolve_rows([row]).get(row.index)

    def test_normalized_isbn13_short_circuits_all_fallbacks(self):
        row = self._row()
        with patch(
            "app.providers.hardcover.lookup_book_by_isbn",
            return_value=self.EXACT_HARDCOVER,
        ) as hardcover_lookup:
            with patch("app.providers.openlibrary.lookup_book_by_isbn") as openlibrary_lookup:
                with patch("integrations.imports.goodreads.services.search") as metadata_search:
                    result = self._resolve(row)

        self.assertEqual(result["media_id"], "exact-hc")
        hardcover_lookup.assert_called_once_with("9780306406157")
        openlibrary_lookup.assert_not_called()
        metadata_search.assert_not_called()

    def test_exact_order_is_hardcover_13_10_then_openlibrary_13_10(self):
        row = self._row()
        events = []

        def hardcover_lookup(isbn):
            events.append((Sources.HARDCOVER.value, isbn))
            return None

        def openlibrary_lookup(isbn):
            events.append((Sources.OPENLIBRARY.value, isbn))
            return self.EXACT_OPENLIBRARY if isbn == "0306406152" else None

        with patch(
            "app.providers.hardcover.lookup_book_by_isbn",
            side_effect=hardcover_lookup,
        ):
            with patch(
                "app.providers.openlibrary.lookup_book_by_isbn",
                side_effect=openlibrary_lookup,
            ):
                with patch("integrations.imports.goodreads.services.search") as metadata_search:
                    result = self._resolve(row)

        self.assertEqual(result["media_id"], "OL-EXACT")
        self.assertEqual(
            events,
            [
                (Sources.HARDCOVER.value, "9780306406157"),
                (Sources.HARDCOVER.value, "0306406152"),
                (Sources.OPENLIBRARY.value, "9780306406157"),
                (Sources.OPENLIBRARY.value, "0306406152"),
            ],
        )
        metadata_search.assert_not_called()

    def test_valid_isbn10_terminal_x_is_preserved(self):
        row = self._row(1)
        result = {**self.EXACT_HARDCOVER, "media_id": "isbn10-x"}
        with patch(
            "app.providers.hardcover.lookup_book_by_isbn",
            side_effect=[None, result],
        ) as hardcover_lookup:
            resolved = self._resolve(row)

        self.assertEqual(resolved["media_id"], "isbn10-x")
        self.assertEqual(
            [call.args[0] for call in hardcover_lookup.call_args_list],
            ["9780975229804", "097522980X"],
        )

    def test_provider_errors_continue_to_next_exact_provider(self):
        row = self._row()
        events = []
        provider_error = services.ProviderAPIError(
            Sources.HARDCOVER.value,
            requests.ConnectionError("Hardcover unavailable"),
        )

        def hardcover_lookup(isbn):
            events.append((Sources.HARDCOVER.value, isbn))
            raise provider_error

        def openlibrary_lookup(isbn):
            events.append((Sources.OPENLIBRARY.value, isbn))
            return self.EXACT_OPENLIBRARY

        with patch(
            "app.providers.hardcover.lookup_book_by_isbn",
            side_effect=hardcover_lookup,
        ):
            with patch(
                "app.providers.openlibrary.lookup_book_by_isbn",
                side_effect=openlibrary_lookup,
            ):
                result = self._resolve(row)

        self.assertEqual(result["media_id"], "OL-EXACT")
        self.assertEqual(
            events,
            [
                (Sources.HARDCOVER.value, "9780306406157"),
                (Sources.HARDCOVER.value, "0306406152"),
                (Sources.OPENLIBRARY.value, "9780306406157"),
            ],
        )

    def test_metadata_fallback_skips_wrong_top_result(self):
        row = self._row()
        wrong = {
            **self.HARDCOVER_METADATA,
            "media_id": "wrong",
            "title": "Atlas of Loud Signals",
        }
        with patch("app.providers.hardcover.lookup_book_by_isbn", return_value=None):
            with patch("app.providers.openlibrary.lookup_book_by_isbn", return_value=None):
                with patch(
                    "integrations.imports.goodreads.services.search",
                    return_value={"results": [wrong, self.HARDCOVER_METADATA]},
                ) as metadata_search:
                    result = self._resolve(row)

        self.assertEqual(result["media_id"], "metadata-hc")
        metadata_search.assert_called_once_with(
            MediaTypes.BOOK.value,
            "Atlas of Quiet Signals Avery North",
            1,
            Sources.HARDCOVER.value,
            preserve_ranking_fields=True,
        )

    def test_metadata_provider_error_falls_back_to_openlibrary(self):
        row = self._row()
        provider_error = services.ProviderAPIError(
            Sources.HARDCOVER.value,
            requests.ConnectionError("Hardcover unavailable"),
        )
        metadata_calls = []

        def metadata_search(_media_type, query, _page, source, **kwargs):
            metadata_calls.append((query, source, kwargs))
            if source == Sources.HARDCOVER.value:
                raise provider_error
            return {"results": [self.OPENLIBRARY_METADATA]}

        with patch("app.providers.hardcover.lookup_book_by_isbn", return_value=None):
            with patch("app.providers.openlibrary.lookup_book_by_isbn", return_value=None):
                with patch(
                    "integrations.imports.goodreads.services.search",
                    side_effect=metadata_search,
                ):
                    result = self._resolve(row)

        self.assertEqual(result["media_id"], "metadata-ol")
        self.assertEqual(
            metadata_calls,
            [
                (
                    "Atlas of Quiet Signals Avery North",
                    Sources.HARDCOVER.value,
                    {"preserve_ranking_fields": True},
                ),
                (
                    "Atlas of Quiet Signals Avery North",
                    Sources.OPENLIBRARY.value,
                    {"preserve_ranking_fields": True},
                ),
            ],
        )

    def test_metadata_mismatches_and_ambiguity_are_rejected(self):
        row = self._row()
        wrong_author = {
            **self.HARDCOVER_METADATA,
            "media_id": "wrong-author",
            "author_name": "Avery South",
        }
        wrong_year = {
            **self.OPENLIBRARY_METADATA,
            "media_id": "wrong-year",
            "first_publish_year": 1995,
        }
        missing_year = {
            key: value
            for key, value in self.OPENLIBRARY_METADATA.items()
            if key != "first_publish_year"
        }
        missing_year["media_id"] = "missing-year"
        with patch("app.providers.hardcover.lookup_book_by_isbn", return_value=None):
            with patch("app.providers.openlibrary.lookup_book_by_isbn", return_value=None):
                with patch(
                    "integrations.imports.goodreads.services.search",
                    side_effect=[
                        {"results": [wrong_author]},
                        {"results": [wrong_year, missing_year]},
                    ],
                ):
                    self.assertIsNone(self._resolve(row))

        ambiguous = [
            self.HARDCOVER_METADATA,
            {**self.HARDCOVER_METADATA, "media_id": "metadata-hc-2"},
        ]
        with patch("app.providers.hardcover.lookup_book_by_isbn", return_value=None):
            with patch("app.providers.openlibrary.lookup_book_by_isbn", return_value=None):
                with patch(
                    "integrations.imports.goodreads.services.search",
                    side_effect=[{"results": ambiguous}, {"results": []}],
                ):
                    self.assertIsNone(self._resolve(row))


class GoodreadsApiTests(TestCase):
    """Test the mobile Goodreads upload and task-polling contract."""

    def setUp(self):
        self.user = get_user_model().objects.create_user(
            username="goodreads-api",
            password="password",
        )
        self.other_user = get_user_model().objects.create_user(
            username="other-goodreads-api",
            password="password",
        )
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def test_csv_file_is_required(self):
        task = Mock()
        task.delay.return_value = SimpleNamespace(id="should-not-queue")
        task_map = {"goodreads": task}
        with patch.dict("api.views.imports.TASKS_BY_SOURCE", task_map, clear=True):
            with patch.dict("api.services.imports.TASKS_BY_SOURCE", task_map, clear=True):
                response = self.client.post(
                    "/api/v1/imports/goodreads/",
                    {"mode": "new"},
                    format="multipart",
                )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("file", response.data["error"]["fields"])
        task.delay.assert_not_called()

    def test_post_queues_temporary_csv_path_and_poll_is_owner_scoped(self):
        task = Mock()
        task.delay.return_value = SimpleNamespace(id="goodreads-task")
        task_map = {"goodreads": task}
        payload = fixture_path.read_bytes()
        upload = SimpleUploadedFile(
            "goodreads_library_export.csv",
            payload,
            content_type="text/csv",
        )

        with patch.dict("api.views.imports.TASKS_BY_SOURCE", task_map, clear=True):
            with patch.dict("api.services.imports.TASKS_BY_SOURCE", task_map, clear=True):
                response = self.client.post(
                    "/api/v1/imports/goodreads/",
                    {"mode": "new", "file": upload},
                    format="multipart",
                )

        self.assertEqual(response.status_code, status.HTTP_202_ACCEPTED)
        self.assertEqual(response.data["task_id"], "goodreads-task")
        queued_path = Path(task.delay.call_args.kwargs["file_path"])
        self.addCleanup(queued_path.unlink, missing_ok=True)
        self.assertEqual(queued_path.suffix, ".csv")
        self.assertEqual(queued_path.read_bytes(), payload)

        TaskResult.objects.create(
            task_id="goodreads-task",
            task_name="Import from Goodreads",
            task_kwargs=(
                f"{{'file_path': '{queued_path}', 'user_id': {self.user.id}, "
                "'mode': 'new'}"
            ),
            status="SUCCESS",
            result="Imported 1 Book.",
        )

        own_poll = self.client.get("/api/v1/imports/tasks/goodreads-task/")
        self.assertEqual(own_poll.status_code, status.HTTP_200_OK)
        self.assertEqual(own_poll.data["status"], "SUCCESS")

        self.client.force_authenticate(self.other_user)
        foreign_poll = self.client.get("/api/v1/imports/tasks/goodreads-task/")
        self.assertEqual(foreign_poll.status_code, status.HTTP_404_NOT_FOUND)


class GoodreadsTaskTests(TestCase):
    """Test that queued Goodreads CSV files are always removed."""

    def _temporary_export(self):
        with tempfile.NamedTemporaryFile(suffix=".csv", delete=False) as export:
            export.write(fixture_path.read_bytes())
        return Path(export.name)

    def test_task_removes_temporary_file_after_success(self):
        path = self._temporary_export()
        self.addCleanup(path.unlink, missing_ok=True)
        observed = {}

        def import_media(importer_func, export_file, user_id, mode):
            observed["importer"] = importer_func
            observed["payload"] = export_file.read()
            observed["user_id"] = user_id
            observed["mode"] = mode
            return "Imported 1 Book."

        with patch("integrations.tasks.import_media", side_effect=import_media):
            result = tasks.import_goodreads(
                file_path=str(path),
                user_id=123,
                mode="new",
            )

        self.assertEqual(result, "Imported 1 Book.")
        self.assertIs(observed["importer"], goodreads.importer)
        self.assertEqual(observed["payload"], fixture_path.read_bytes())
        self.assertEqual(observed["user_id"], 123)
        self.assertEqual(observed["mode"], "new")
        self.assertFalse(path.exists())

    def test_task_removes_temporary_file_when_import_fails(self):
        path = self._temporary_export()
        self.addCleanup(path.unlink, missing_ok=True)

        with patch(
            "integrations.tasks.import_media",
            side_effect=RuntimeError("import failed"),
        ):
            with self.assertRaisesRegex(RuntimeError, "import failed"):
                tasks.import_goodreads(
                    file_path=str(path),
                    user_id=123,
                    mode="new",
                )

        self.assertFalse(path.exists())
