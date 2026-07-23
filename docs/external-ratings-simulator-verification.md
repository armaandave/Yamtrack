# External-Rating Simulator Verification

Status: **UNVERIFIED**

Use an iPhone 17 Simulator, disposable PostgreSQL/Redis containers, a disposable
account, and a runtime-only `SPINE_API_BASE_URL=http://127.0.0.1:8000`. Do not
use production data, credentials, or provider calls. Seed stored ratings with
`bulk_create` so the smoke run is deterministic.

Record the commit, simulator OS, disposable database/container names, migration
head, test account confirmation without credentials, and sanitized screenshots.

- [ ] Movie Library advertises and sends `rating:imdb`; the server's highest
      stored IMDb value is first and paging preserves the token/direction.
- [ ] Book Library advertises and sends `rating:hardcover`; server order is
      rendered without device sorting.
- [ ] Game Library advertises and sends `rating:metacritic`; ascending and
      descending both preserve nulls-last behavior.
- [ ] No optional rating-provider call appears in backend logs during any GET.
- [ ] Changing sort replaces page 1 and a stale prior page does not append.
- [ ] Containers, disposable database/account, runserver, and runtime override
      are removed after verification.

Do not mark this record verified without visible Simulator evidence and matching
sanitized API/database checks.
