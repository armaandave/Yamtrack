from decimal import Decimal

from rest_framework import serializers

from app.models import Status


class TrackingWriteSerializer(serializers.Serializer):
    """Validate generic tracking writes."""

    status = serializers.ChoiceField(choices=Status.values, required=False)
    rating = serializers.DecimalField(
        max_digits=3,
        decimal_places=1,
        min_value=Decimal(0),
        max_value=Decimal(10),
        required=False,
        allow_null=True,
    )
    progress = serializers.IntegerField(min_value=0, required=False)
    start_date = serializers.DateTimeField(required=False, allow_null=True)
    end_date = serializers.DateTimeField(required=False, allow_null=True)
    notes = serializers.CharField(required=False, allow_blank=True)
    season_number = serializers.IntegerField(required=False, allow_null=True)
    mutation_id = serializers.UUIDField(required=False, allow_null=True)


class ConsumeSerializer(serializers.Serializer):
    """Validate consume action payloads."""

    consumed_at = serializers.DateTimeField(required=False, allow_null=True)
    create_diary_entry = serializers.BooleanField(required=False, default=False)


class EpisodeWatchSerializer(serializers.Serializer):
    """Validate watched episode payloads."""

    watched_at = serializers.DateTimeField(required=False, allow_null=True)


class BookProgressSerializer(serializers.Serializer):
    """Validate book progress payloads."""

    progress_type = serializers.ChoiceField(choices=["pages", "percentage"])
    value = serializers.DecimalField(max_digits=8, decimal_places=2, min_value=Decimal(0))
    notes = serializers.CharField(required=False, allow_blank=True)
    progressed_on = serializers.DateField(required=False)


class BookActionSerializer(serializers.Serializer):
    """Validate an idempotent book journey/status action."""

    mutation_id = serializers.UUIDField(required=False, allow_null=True)
    start_date = serializers.DateField(required=False, allow_null=True)
    end_date = serializers.DateField(required=False, allow_null=True)


class BookJourneyWriteSerializer(serializers.Serializer):
    """Validate editable book journey dates."""

    start_date = serializers.DateField(required=False, allow_null=True)
    end_date = serializers.DateField(required=False, allow_null=True)


class BookCompletionSerializer(serializers.Serializer):
    """Validate the atomic book completion composer payload."""

    journey_id = serializers.IntegerField(required=False, allow_null=True, min_value=1)
    completion_date = serializers.DateField()
    rating = serializers.DecimalField(
        max_digits=2,
        decimal_places=1,
        min_value=Decimal("0.5"),
        max_value=Decimal("5.0"),
        required=False,
        allow_null=True,
    )
    review = serializers.CharField(required=False, allow_blank=True, default="")
    review_title = serializers.CharField(required=False, allow_blank=True, default="")
    liked = serializers.BooleanField(required=False, default=False)
    is_rewatch = serializers.BooleanField(required=False, default=False)
    contains_spoilers = serializers.BooleanField(required=False, default=False)
    tags = serializers.ListField(
        child=serializers.CharField(allow_blank=False),
        required=False,
        default=list,
    )
    mutation_id = serializers.UUIDField()

    def validate_rating(self, value):
        """Accept only the shared ten half-star values."""
        if value is not None and value * 2 != (value * 2).to_integral_value():
            raise serializers.ValidationError(
                "Rating must be a half-star value from 0.5 to 5.0.",
            )
        return value
