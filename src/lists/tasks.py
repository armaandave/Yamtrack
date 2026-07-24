"""Celery tasks for native Spine lists."""

from celery import shared_task
from django.core.management import call_command


@shared_task(name="Sync NYT featured lists")
def sync_nyt_featured_lists():
    """Refresh the approved NYT Best Sellers lists owned by Spine."""
    return call_command("sync_nyt_featured_lists", owner="Spine")
