from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone

from app.models import Item, MediaTypes
from app.providers import hardcover, nytbooks, openlibrary
from lists.models import CustomList, CustomListItem

LIST_TAGS = ["NYT Best Sellers", "Books"]


def _resolve_book(book):
    for lookup in (hardcover.lookup_book_by_isbn, openlibrary.lookup_book_by_isbn):
        for isbn in book["isbns"]:
            result = lookup(isbn)
            if result:
                return result
    return None


def _get_or_create_item(result, fallback_title):
    source = str(result["source"])
    media_id = str(result["media_id"])
    title = result.get("title") or fallback_title or media_id
    image = result.get("image") or settings.IMG_NONE
    total_pages = result.get("total_pages") or result.get("max_progress")
    item, _ = Item.objects.get_or_create(
        source=source,
        media_type=MediaTypes.BOOK.value,
        media_id=media_id,
        defaults={
            "title": title,
            "image": image,
            "total_pages": total_pages,
        },
    )

    update_fields = []
    if title and item.title != title:
        item.title = title
        update_fields.append("title")
    if image and item.image != image:
        item.image = image
        update_fields.append("image")
    if total_pages and item.total_pages is None:
        item.total_pages = total_pages
        update_fields.append("total_pages")
    if update_fields:
        item.save(update_fields=update_fields)
    return item


def _sync_chart(owner, definition, chart):
    resolved_count = 0
    resolved = []
    seen = set()
    for book in chart["books"]:
        result = _resolve_book(book)
        if not result:
            continue
        resolved_count += 1
        identity = (str(result["source"]), str(result["media_id"]))
        if identity in seen:
            continue
        seen.add(identity)
        resolved.append((book, result))

    if not resolved:
        raise CommandError(
            f"{chart['name']}: no books resolved. Existing contents were preserved.",
        )

    with transaction.atomic():
        ranked_items = [
            (book["rank"], _get_or_create_item(result, book["title"]))
            for book, result in resolved
        ]
        custom_list, _ = CustomList.objects.get_or_create(
            owner=owner,
            import_source="nyt",
            import_source_id=definition["slug"],
            defaults={
                "name": definition["display_name"],
                "slug": f"nyt-{definition['slug']}",
            },
        )
        custom_list.name = definition["display_name"]
        custom_list.slug = f"nyt-{definition['slug']}"
        custom_list.description = (
            f"The New York Times Best Sellers list published {chart['published_date']}."
            if chart["published_date"]
            else "The current New York Times Best Sellers list."
        )
        custom_list.tags = LIST_TAGS
        custom_list.visibility = CustomList.Visibility.PUBLIC
        custom_list.is_ranked = True
        custom_list.import_source_url = (
            f"https://www.nytimes.com/books/best-sellers/{definition['slug']}/"
        )
        custom_list.is_featured = True
        custom_list.featured_position = definition["featured_position"]
        custom_list.last_synced_at = timezone.now()
        custom_list.save()

        CustomListItem.objects.filter(custom_list=custom_list).delete()
        CustomListItem.objects.bulk_create(
            [
                CustomListItem(
                    custom_list=custom_list,
                    item=item,
                    position=rank,
                )
                for rank, item in ranked_items
            ],
        )
    return custom_list, len(ranked_items), resolved_count


class Command(BaseCommand):
    help = "Synchronize the approved NYT Best Sellers charts into featured Spine lists"

    def add_arguments(self, parser):
        parser.add_argument("--owner", required=True)

    def handle(self, *args, **options):  # noqa: ARG002
        try:
            owner = get_user_model().objects.get(username=options["owner"])
        except get_user_model().DoesNotExist as error:
            raise CommandError(f"Spine user {options['owner']!r} does not exist.") from error

        failures = []
        for definition in nytbooks.FEATURED_CHARTS:
            try:
                chart = nytbooks.get_current_chart(
                    definition["slug"],
                    definition["fallback_name"],
                )
                custom_list, stored_count, resolved_count = _sync_chart(
                    owner,
                    definition,
                    chart,
                )
            except Exception as error:  # noqa: BLE001
                failures.append((definition["slug"], error))
                self.stderr.write(
                    self.style.ERROR(f"{definition['fallback_name']}: {error}"),
                )
                continue

            self.stdout.write(
                self.style.SUCCESS(
                    f"Synced {stored_count} ranked items into {custom_list.name!r} "
                    f"({resolved_count}/{len(chart['books'])} NYT entries resolved).",
                ),
            )

        if failures:
            failed = ", ".join(slug for slug, _ in failures)
            raise CommandError(
                f"{len(failures)} of {len(nytbooks.FEATURED_CHARTS)} NYT charts failed: {failed}.",
            )
