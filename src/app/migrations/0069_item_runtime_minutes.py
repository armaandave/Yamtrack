from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("app", "0068_item_filter_metadata"),
    ]

    operations = [
        migrations.AddField(
            model_name="item",
            name="runtime_minutes",
            field=models.PositiveIntegerField(blank=True, null=True),
        ),
        migrations.AddIndex(
            model_name="item",
            index=models.Index(fields=["media_type", "runtime_minutes"], name="app_item_media_t_58d797_idx"),
        ),
    ]
