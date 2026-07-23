from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("users", "0057_user_display_name_profile_public_default"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="profile_backdrop_url",
            field=models.URLField(blank=True, default="", help_text="Selected profile backdrop image URL", max_length=1000),
        ),
        migrations.AddField(
            model_name="user",
            name="profile_backdrop_item",
            field=models.ForeignKey(
                blank=True,
                help_text="Media item used for the selected profile backdrop",
                null=True,
                on_delete=models.SET_NULL,
                related_name="+",
                to="app.item",
            ),
        ),
    ]
