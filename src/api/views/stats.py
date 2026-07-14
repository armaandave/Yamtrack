from django.contrib.auth import get_user_model
from django.shortcuts import get_object_or_404
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from api.permissions import can_view_user_profile
from api.serializers.common import media_summary_from_item
from api.services import stats as stats_service
from app import statistics as legacy_stats


def stats_payload(user, request):
    """Build legacy chart keys plus the native-client stats contract."""
    stats_range = stats_service.parse_stats_range(request.query_params)
    native_payload = stats_service.build_stats_payload(
        user=user,
        viewer=request.user,
        request=request,
        stats_range=stats_range,
    )
    user_media, media_count = legacy_stats.get_user_media(
        user,
        stats_range.start_datetime,
        stats_range.end_datetime,
    )
    if request.user == user:
        score_distribution, top_rated = legacy_stats.get_score_distribution(user_media)
        legacy_top_rated = [
            {
                "media": media_summary_from_item(
                    media.item,
                    request=request,
                    user=None,
                    include_user_state=False,
                ),
                "rating": str(media.score) if media.score is not None else None,
            }
            for media in top_rated
        ]
    else:
        # Tracking scores have no per-entry visibility. Public legacy fields
        # therefore project the already-filtered diary data instead.
        score_distribution = stats_service.legacy_score_distribution(native_payload)
        legacy_top_rated = native_payload["diary_top_rated"]
    status_distribution = legacy_stats.get_status_distribution(user_media)
    payload = {
        "start_date": stats_range.start_datetime,
        "end_date": stats_range.end_datetime,
        "media_count": media_count,
        "media_type_distribution": legacy_stats.get_media_type_distribution(media_count),
        "score_distribution": score_distribution,
        "status_distribution": status_distribution,
        "top_rated": legacy_top_rated,
    }
    payload.update(native_payload)
    return payload


class MyStatsSummaryView(APIView):
    """Current user's stats summary."""

    permission_classes = [IsAuthenticated]

    def get(self, request):
        return Response(stats_payload(request.user, request))


class UserStatsSummaryView(APIView):
    """Public user's stats summary."""

    permission_classes = [IsAuthenticated]

    def get(self, request, username):
        user = get_object_or_404(get_user_model(), username=username)
        if not can_view_user_profile(request.user, user):
            return Response(status=status.HTTP_404_NOT_FOUND)
        return Response(stats_payload(user, request))
