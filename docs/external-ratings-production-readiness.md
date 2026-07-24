# External-Rating Production Readiness

The production backfill controls add no migration and do not automatically
deploy or start a backfill. Migrations `0073_externalrating` and
`0074_migrate_legacy_external_ratings` stay additive; the three legacy `Item`
rating columns and aliases remain supported.

## Provider coverage

| Key | Eligible identity | Scale | Upstream grouping | Freshness | Production note |
| --- | --- | ---: | --- | --- | --- |
| `tmdb` | TMDB movie/TV/season/episode | 10 | Required metadata | 24h | TMDB credentials/terms required |
| `imdb` | TMDB movie/TV/season | 10 | One MDBList call with Letterboxd/Tomatoes | 24h | MDBList policy required |
| `imdb` | Exact TMDB episode | 10 | Licensed IMDb Data Exchange helper | 24h | Skipped unless licensed settings exist |
| `letterboxd` | TMDB movie/TV/season | 5 | Grouped MDBList | 24h | MDBList policy required |
| `tomatoes` | TMDB movie/TV/season | 100 | Grouped MDBList | 24h | MDBList policy required |
| `mal` | MAL anime/manga | 10 | Native metadata | 24h | 30 requests/minute |
| `mangaupdates` | MangaUpdates manga | 10 | Native metadata | 24h | Provider policy required |
| `igdb` | IGDB game | 100 | Native metadata | 24h | 3 requests/second |
| `metacritic` | IGDB game | 100 | Steam/IGDB mapping helper | 24h | Steam 3 requests/second |
| `steam` | IGDB game | 100% | Lifetime Steam-purchase reviews via IGDB mapping | 24h | Steam Store host 3 requests/second |
| `openlibrary` | Open Library book | 5 | Native metadata | 24h | 20 requests/minute |
| `hardcover` | Hardcover book | 5 | Native metadata | 24h | 50 requests/minute |
| `musicbrainz` | MusicBrainz release group | 5 | Native metadata | 24h | Runtime-disabled pending written approval; 1 request/second |

ComicVine ratings, manual Items, TVDB-only identities, Goodreads, and malformed
source/media combinations remain unsupported. Spine backfills all known `Item`
rows only; it never crawls a provider's complete universe.

## Readiness checks

Run from `src/` in the deployed app container:

```bash
python manage.py showmigrations app
python manage.py external_rating_status
python manage.py backfill_external_ratings --rating-source imdb --media-type movie --item-source tmdb --batch-size 25 --limit 500 --dry-run
celery -A config inspect registered
celery -A config inspect active
celery -A config inspect reserved
```

Task logs emit JSON after `external_rating_item_summary` and
`external_rating_batch_summary`. Item summaries contain `attempted`,
`available`, `unavailable`, `failed`, `skipped_fresh`, and `preserved_stale`.
They contain no provider response, URL, credential, or error body.

The production image supervises Gunicorn, one concurrency-one Celery worker,
and beat in one container. Rebuilding the app starts all three; verify worker
registration explicitly. The worker processes a maximum 100-Item batch
sequentially and is recycled after every task.

## Owner-controlled rollout

Use the manually dispatched **External Ratings Production Backfill** workflow:

1. Deploy the approved commit; deployment and backfill cannot overlap.
2. Run `inventory/all` and review every eligible, covered, missing, unavailable,
   and failed count in the job summary.
3. Run `backup/all` with the provider-rights confirmation. The workflow checks
   disk space, creates a custom-format dump, verifies its restore listing,
   records its checksum, and writes a commit-bound campaign marker.
4. Run `canary/mdblist_movie` with the production-write confirmation. A passing
   canary must finish exactly 10 missing/failed Items without a failed, partial,
   retrying, timed-out, malformed, or non-progressing batch.
5. Run `backfill/mdblist_movie`; rerun if the four-hour limit reports a clean
   resumable pause.
6. Require scoped coverage inventory to reach zero, API health to remain green,
   and IMDb/Letterboxd/Rotten Tomatoes/Steam sorting to pass in Simulator.
7. Repeat canary then backfill for one scope at a time in this order: TMDB
   movies; TV, seasons, and episodes; MAL/MangaUpdates; IGDB/Metacritic/Steam;
   OpenLibrary/Hardcover; and finally approved MusicBrainz. IMDb episodes require
   licensed runtime configuration.
8. Run final all-scope inventory and Simulator smoke tests. Enable person
   filmography preparation only in a later deployment after monitoring remains
   healthy.

For `steam_game`, run the commit-bound backup, a 10-game canary, and the full
scope drain. Completion requires zero missing/failed pairs; `unavailable` is a
valid terminal outcome for games without a Steam mapping or qualifying reviews.

The workflow defaults to 500-Item selection waves and one outstanding 25-Item
Celery task. It stops immediately after any failure or retry. Stale successful
terminal rows remain sortable and are refreshed by daily maintenance rather
than blocking coverage completion.

## Pause and rollback

Canceling the workflow stops future batch submission; its already-running Celery
batch finishes normally. Do not purge Redis. Rerun the same scope to resume from
missing/failed coverage.

For rollback, set both Phase 10 flags false, stop further enqueueing, and
redeploy the previous backend/iOS version. Older code ignores additive
`ExternalRating` rows and continues using dual-written legacy columns. Do not
reverse migration `0074`—its reverse is intentionally a no-op. Restore the
database backup only for verified data corruption.

## Go/no-go

Production is **NO-GO** until all required provider terms and credentials are
owner-confirmed, migration drift and lint are clean, broad backend/iOS tests
pass, task discovery succeeds, the 5,000-row query/50 ms latency gates pass on
SQLite and disposable PostgreSQL, and the non-production movie/book/game
simulator smoke record is complete.

## Local Phase 10 verification (2026-07-21)

This record is local evidence only; no production system or live rating provider
was contacted.

- Focused external-rating backend suite: 68 tests passed.
- API v1 suite: 177 tests passed.
- Migration drift: none; Ruff: clean for `src/` and touched Python files.
- A 5,000-Item SQLite fixture used 9 queries for title sorting and 10 for IMDb
  sorting at both 25- and 100-row pages. Warm external-sort p50 overhead was
  7.50 ms in isolation and 11.38 ms during the parallel suite, below 50 ms.
- SQLite used the unique `(item_id, rating_source)` constraint index and a
  temporary B-tree for the unavoidable final ordering step.
- The iPhone 17 build passed. All external-rating Swift tests passed. The full
  scheme had one failure in an unrelated token-refresh test; that test passed
  immediately when rerun alone, so the full-suite gate remains formally red.
- The 1,134-test broad Django run had nine errors. Seven reproduced in the
  legacy `lists` suite because its fixtures attempted live TMDB requests; no
  Phase 10 assertion failed. The agreed no-live-network broad-suite gate remains
  red until those fixtures mock provider access.
- Disposable PostgreSQL 16/Redis were unavailable locally, so PostgreSQL plan
  evidence, task discovery against Redis, and the movie/book/game simulator
  smoke were not run. See `external-ratings-simulator-verification.md`.
- Provider credentials, quotas, and legal/licensing approvals are owner-side
  production gates and were not inspected. MusicBrainz stays disabled.

Result: **NO-GO**. Resolve every red or unverified gate and rerun the complete
checklist before authorizing deployment or a production backfill.
