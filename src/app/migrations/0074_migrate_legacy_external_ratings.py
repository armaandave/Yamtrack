from django.db import migrations
from django.utils import timezone


LEGACY_RATINGS = (
    ("letterboxd_rating", "letterboxd", 5),
    ("imdb_rating", "imdb", 10),
    ("rotten_tomatoes_rating", "tomatoes", 100),
)


def migrate_legacy_external_ratings(apps, schema_editor):
    Item = apps.get_model("app", "Item")
    ExternalRating = apps.get_model("app", "ExternalRating")
    fallback_timestamp = timezone.now()
    pending = []

    for item in Item.objects.iterator(chunk_size=1000):
        attempted_at = item.filter_metadata_updated_at or fallback_timestamp
        for field, source, max_value in LEGACY_RATINGS:
            value = getattr(item, field)
            if value is None:
                continue
            pending.append(
                ExternalRating(
                    item_id=item.pk,
                    rating_source=source,
                    value=value,
                    max_value=max_value,
                    status="available",
                    last_attempted_at=attempted_at,
                    last_success_at=attempted_at,
                ),
            )
            if len(pending) == 1000:
                ExternalRating.objects.bulk_create(pending, ignore_conflicts=True)
                pending.clear()

    if pending:
        ExternalRating.objects.bulk_create(pending, ignore_conflicts=True)


class Migration(migrations.Migration):
    dependencies = [
        ("app", "0073_externalrating"),
    ]

    operations = [
        migrations.RunPython(
            migrate_legacy_external_ratings,
            reverse_code=migrations.RunPython.noop,
        ),
    ]
