from django.db import migrations, models
from django.db.models import Q


class Migration(migrations.Migration):

    dependencies = [
        ("lists", "0006_customlist_tags"),
    ]

    operations = [
        migrations.AddField(
            model_name="customlist",
            name="featured_position",
            field=models.PositiveIntegerField(default=0),
        ),
        migrations.AddField(
            model_name="customlist",
            name="import_source_id",
            field=models.CharField(blank=True, default="", max_length=255),
        ),
        migrations.AddField(
            model_name="customlist",
            name="import_source_url",
            field=models.URLField(blank=True, default="", max_length=2048),
        ),
        migrations.AddField(
            model_name="customlist",
            name="is_featured",
            field=models.BooleanField(db_index=True, default=False),
        ),
        migrations.AddField(
            model_name="customlist",
            name="last_synced_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddConstraint(
            model_name="customlist",
            constraint=models.UniqueConstraint(
                condition=~Q(import_source_id=""),
                fields=("owner", "import_source", "import_source_id"),
                name="lists_customlist_unique_import",
            ),
        ),
    ]
