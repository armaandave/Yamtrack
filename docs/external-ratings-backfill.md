# External-Rating Backfill Operations

The backfill command queues ratings only for media already represented by an
`Item`. It never searches an upstream catalog or calls a rating provider in the
management-command process.

## Prerequisites

1. Apply migrations through `0074_migrate_legacy_external_ratings`.
2. Confirm Redis, the Celery worker, and the existing provider credentials are
   available. Licensed IMDb episode ratings also require all IMDb Data Exchange
   settings.
3. Confirm the worker discovers `Enrich external ratings` and
   `Enrich external ratings batch`.
4. Run the intended scope with `--dry-run` before queueing it.

From `src/`, inspect the whole known catalog:

```bash
python manage.py backfill_external_ratings --dry-run
```

Inspect persisted row health without queueing anything:

```bash
python manage.py external_rating_status
python manage.py external_rating_status --rating-source imdb --media-type movie
```

The status report groups rows by rating source, media type, outcome, and
freshness. Registered available/unavailable rows inside their source policy are
`fresh`; expired or failed registered rows are `stale`; free-form keys absent
from the current registry are `unregistered`. Use the backfill dry run for
missing Item/source pairs, because a status report can only count rows that
exist.

Scope work by repeating filters when necessary:

```bash
python manage.py backfill_external_ratings \
  --rating-source imdb \
  --media-type movie \
  --item-source tmdb \
  --batch-size 25 \
  --limit 500 \
  --dry-run
```

Remove `--dry-run` only after reviewing the counts. `--force` refreshes fresh
terminal rows too and should be reserved for deliberate provider-wide repairs.

## Reading the Report

Eligibility and rating-state counts use Item/source pairs because one Item may
have several ratings. Item and batch counts are also printed separately.

- **Already fresh terminal** means a fresh `available` or `unavailable` row.
- **Pending/missing** includes missing rows, failed rows, and stale terminal rows.
- **Unavailable** and **failed** report current row states, so they can overlap
  the freshness and pending counts.
- **Selected Items** applies `--limit` after pending detection. Batches equal
  `ceil(selected Items / batch size)`.

Repeated limited runs advance naturally after completed rows become fresh. If a
run is repeated while its tasks are still queued, duplicate messages are
possible, but task freshness checks, item locks, and the database uniqueness
constraint prevent duplicate provider work and duplicate rating rows.

## Capacity and Provider Limits

The default batch contains 100 Items and the production worker configuration
uses one process. Each batch processes Items sequentially. Smaller batches make
pause/resume and provider-specific rollout easier.

Item/source pairs are not the same as HTTP requests:

- One MDBList operation emits IMDb, Letterboxd, and Rotten Tomatoes for a TMDB
  movie, TV show, or season.
- A TMDB episode may use its shared metadata lookup plus the optional licensed
  IMDb lookup.
- An IGDB game may use its metadata lookup plus the Steam/Metacritic mapping.
- MAL, MangaUpdates, OpenLibrary, Hardcover, MusicBrainz, and other native
  registry sources generally use one cached metadata operation per Item.
- Existing provider caches can eliminate upstream requests entirely.

Current shared limits include a five-request-per-second default limiter, MAL at
30 requests/minute, IGDB at 3/second, OpenLibrary at 20/minute, Hardcover at
50/minute, and MusicBrainz in its own shared Redis bucket at 1/second. Steam
requests are limited to 3/second. Provider licensing and account quotas still
apply even when the local limiter permits more work.

MusicBrainz ratings are additionally gated by
`MUSICBRAINZ_EXTERNAL_RATINGS_ENABLED=False`. Do not enable or backfill that
source until the owner records the required supplementary-data/account approval.

## Monitor, Pause, Resume, and Validate

Inspect Celery while a run is active:

```bash
celery -A config inspect active
celery -A config inspect reserved
celery -A config inspect stats
```

Monitor worker logs for the compact item/batch outcome counts and inspect
`TaskResult` plus `ExternalRating` status/error fields in Django admin. Watch for
rate limiting, authentication failures, repeated transient retries, and a
growing Redis queue.

For a controlled pause, use bounded `--limit` runs and stop issuing the next
command. `Ctrl-C` stops any remaining command-side enqueueing. Gracefully stop
the Celery worker to pause consumption; already queued messages remain in Redis.
Restart the worker and rerun the same command to resume. Letting the existing
queue drain before rerunning avoids redundant messages.

After completion, rerun the same scope with `--dry-run`. Selected Items should
reach zero unless rows failed or became stale. Review failed rows and spot-check
media-detail output before expanding to another provider or media type.

## Adding a Future Provider

Goodreads is intentionally unsupported until Spine has an approved, reliable,
and legally acceptable source. The exact future flow is:

1. Confirm a lawful, reliable source and record its policy, credentials, limits,
   caching permission, attribution, and scale.
2. Add one registry fetch operation plus applicability, freshness, scale, and
   mocked tests. No schema or client enum change is required.
3. Deploy the code and restart web and Celery processes so the registry and task
   discovery agree.
4. Dry-run the scoped known-book catalog:

   ```bash
   python manage.py backfill_external_ratings \
     --rating-source goodreads \
     --media-type book \
     --dry-run
   ```

5. Queue a small limited real backfill, monitor it, validate status counts and
   stored outcomes, and then
   increase the limit or remove it.
6. Rerun the same scoped command after interruption; fresh successes and
   authoritative unavailable rows are skipped automatically.
7. Let the existing dynamic filter-options response expose the registered source.

`Item` is Spine's known catalog: tracked media, imported media, list/detail
materializations, and supported person credits. A backfill never enumerates an
upstream provider's complete catalog. Manual Items, ComicVine ratings, TVDB-only
identities, and unsupported source/media pairs are skipped rather than failed.

The legacy `Item.letterboxd_rating`, `Item.imdb_rating`, and
`Item.rotten_tomatoes_rating` columns remain deprecated compatibility storage
for old sort readers. `ExternalRating` owns durable rating state.
