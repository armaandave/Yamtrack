from contextlib import contextmanager
from contextvars import ContextVar


_external_rating_item_ids = ContextVar("external_rating_item_ids", default=None)


class CalendarTriggerMixin:
    """Mixin to handle calendar trigger disabling functionality."""

    _disable_calendar_triggers = False  # Instance-level flag


def disable_fetch_releases():
    """Context manager to disable fetching releases task.

    Applies for models using CalendarTriggerMixin.
    """
    return _DisableCalendarTriggers()


@contextmanager
def collect_external_rating_item_ids():
    """Collect created eligible Item IDs for one bounded enqueue point."""
    item_ids = set()
    token = _external_rating_item_ids.set(item_ids)
    try:
        yield item_ids
    finally:
        _external_rating_item_ids.reset(token)


def collect_external_rating_item_id(item_id):
    """Return whether an active collector accepted an Item ID."""
    item_ids = _external_rating_item_ids.get()
    if item_ids is None:
        return False
    item_ids.add(item_id)
    return True


class _DisableCalendarTriggers:
    """Context manager for disabling calendar triggers during bulk operations."""

    def __enter__(self):
        """Disable calendar triggers for Item model."""
        from app.models import Item  # noqa: PLC0415

        self.original_value = Item._disable_calendar_triggers
        Item._disable_calendar_triggers = True
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Restore calendar triggers."""
        from app.models import Item  # noqa: PLC0415

        Item._disable_calendar_triggers = self.original_value
