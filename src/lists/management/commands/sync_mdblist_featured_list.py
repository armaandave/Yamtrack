from urllib.parse import urlparse

from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone

from app.models import Item, MediaTypes, Sources
from app.providers import mdblist
from lists.models import CustomList, CustomListItem


def external_list_id(value):
    """Return an MDBList external-list ID from an ID or public URL."""
    raw = str(value).strip().rstrip("/")
    candidate = urlparse(raw).path.rsplit("/", 1)[-1] if "://" in raw else raw
    if not candidate.isdigit():
        raise CommandError("External list must be an MDBList list ID or URL.")
    return candidate


def poster_url(payload):
    """Return a usable poster URL from MDBList's optional poster field."""
    value = payload.get("poster") or payload.get("poster_path")
    if isinstance(value, dict):
        value = value.get("url") or value.get("large") or value.get("medium")
    if isinstance(value, str) and value.startswith("/"):
        return f"https://image.tmdb.org/t/p/original{value}"
    return value or settings.IMG_NONE


class Command(BaseCommand):
    help = "Synchronize one MDBList external list into a featured native Spine list"

    def add_arguments(self, parser):
        parser.add_argument("external_list")
        parser.add_argument("--owner", required=True)
        parser.add_argument("--featured-position", type=int, default=1)

    def handle(self, *args, **options):  # noqa: ARG002
        list_id = external_list_id(options["external_list"])
        source_url = options["external_list"] if "://" in options["external_list"] else ""
        try:
            owner = get_user_model().objects.get(username=options["owner"])
        except get_user_model().DoesNotExist as error:
            raise CommandError(f"Spine user {options['owner']!r} does not exist.") from error

        metadata = mdblist.get_external_list(list_id)
        remote_items = mdblist.get_external_list_items(list_id)
        expected_count = int(metadata.get("items") or 0)
        identities = {
            (item["spine_media_type"], str(item.get("ids", {}).get("tmdb") or item.get("id")))
            for item in remote_items
            if item.get("ids", {}).get("tmdb") or item.get("id")
        }
        if not identities:
            raise CommandError("MDBList returned no importable TMDB items; the existing list was not changed.")
        if expected_count and len(identities) != expected_count:
            raise CommandError(
                f"MDBList reported {expected_count} items but returned {len(identities)} unique TMDB items; "
                "the existing list was not changed."
            )

        ordered = sorted(
            (
                item
                for item in remote_items
                if (item["spine_media_type"], str(item.get("ids", {}).get("tmdb") or item.get("id"))) in identities
            ),
            key=lambda item: (item.get("rank") is None, item.get("rank") or 0),
        )

        with transaction.atomic():
            existing = {
                (item.media_type, item.media_id): item
                for item in Item.objects.filter(
                    source=Sources.TMDB.value,
                    media_type__in=[MediaTypes.MOVIE.value, MediaTypes.TV.value],
                    media_id__in=[media_id for _, media_id in identities],
                )
            }
            Item.objects.bulk_create(
                [
                    Item(
                        source=Sources.TMDB.value,
                        media_type=media_type,
                        media_id=media_id,
                        title=payload.get("title") or media_id,
                        image=poster_url(payload),
                        release_year=payload.get("release_year"),
                    )
                    for payload in ordered
                    if (
                        media_type := payload["spine_media_type"],
                        media_id := str(payload.get("ids", {}).get("tmdb") or payload.get("id")),
                    )
                    not in existing
                ],
                ignore_conflicts=True,
                batch_size=500,
            )
            stored = {
                (item.media_type, item.media_id): item
                for item in Item.objects.filter(
                    source=Sources.TMDB.value,
                    media_type__in=[MediaTypes.MOVIE.value, MediaTypes.TV.value],
                    media_id__in=[media_id for _, media_id in identities],
                )
            }
            custom_list, _ = CustomList.objects.get_or_create(
                owner=owner,
                import_source="mdblist",
                import_source_id=list_id,
                defaults={"name": metadata.get("name") or f"MDBList {list_id}"},
            )
            custom_list.name = metadata.get("name") or custom_list.name
            custom_list.visibility = CustomList.Visibility.PUBLIC
            custom_list.is_ranked = True
            custom_list.is_featured = True
            custom_list.featured_position = max(options["featured_position"], 0)
            if source_url:
                custom_list.import_source_url = source_url
            custom_list.last_synced_at = timezone.now()
            custom_list.save()

            CustomListItem.objects.filter(custom_list=custom_list).delete()
            CustomListItem.objects.bulk_create(
                [
                    CustomListItem(
                        custom_list=custom_list,
                        item=stored[
                            (
                                payload["spine_media_type"],
                                str(payload.get("ids", {}).get("tmdb") or payload.get("id")),
                            )
                        ],
                        position=index,
                    )
                    for index, payload in enumerate(ordered, start=1)
                ],
                batch_size=500,
            )

        self.stdout.write(
            self.style.SUCCESS(
                f"Synced {len(ordered)} items into featured list {custom_list.name!r} owned by {owner.username}."
            )
        )
