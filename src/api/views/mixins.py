"""Shared API view mixins."""

from app import exposure


class MediaExposureMixin:
    """Reject client media types hidden by the rollout policy."""

    def initial(self, request, *args, **kwargs):
        media_type = kwargs.get("media_type") or request.query_params.get("media_type")
        if media_type is None and request.method != "GET":
            media_type = request.data.get("media_type")
        exposure.require_media_type(media_type)
        return super().initial(request, *args, **kwargs)
