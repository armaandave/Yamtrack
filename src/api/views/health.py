from django.conf import settings
from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from app import exposure
from app.models import Status
from users.models import (
    DateFormatChoices,
    QuickWatchDateChoices,
    TimeFormatChoices,
    WeekStartDayChoices,
)


def choice_payload(choices):
    """Serialize Django choice tuples for mobile pickers."""
    return [{"value": value, "label": label} for value, label in choices]


class HealthView(APIView):
    """Lightweight API health endpoint."""

    permission_classes = [AllowAny]

    def get(self, request):
        return Response(
            {
                "status": "ok",
                "version": settings.VERSION,
                "time": timezone.now(),
            },
        )


class MetaView(APIView):
    """API metadata for clients."""

    permission_classes = [AllowAny]

    def get(self, request):
        return Response(
            {
                "version": "v1",
                "media_types": exposure.media_types(),
                "sources": exposure.source_map(),
                "status_choices": list(Status.values),
                "source_choices": exposure.source_values(),
                "date_formats": choice_payload(DateFormatChoices.choices),
                "time_formats": choice_payload(TimeFormatChoices.choices),
                "week_start_days": choice_payload(WeekStartDayChoices.choices),
                "quick_watch_dates": choice_payload(QuickWatchDateChoices.choices),
            },
        )
