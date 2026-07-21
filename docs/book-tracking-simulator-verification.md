# Book Tracking Simulator Verification Record

Overall status: **VERIFIED**

This credential-free record covers the authenticated iPhone 17 acceptance run for the numbered laws in `docs/book-tracking-contract.md`. Account identity, credentials, tokens, cookies, provider keys, and authorization headers are intentionally omitted.

## Run metadata

| Field | Recorded value |
| --- | --- |
| Verification completed | 2026-07-21 01:20 PDT (08:20 UTC) |
| Operator | Codex automated acceptance run |
| Git branch / starting HEAD | `search-page-ios` / `69d8f999` |
| Worktree | Dirty by design; book-tracking changes plus pre-existing external-rating, person-search, and search edits were reviewed and preserved. No commit was created. |
| Backend settings / database | `spine_book_sim_settings`; disposable SQLite database at `/private/tmp/spine_book_sim_019f8347.sqlite3` |
| Migration head | `app.0075_book_current_session_book_like_is_independent_and_more` |
| Deterministic fixture | `sim-book-contract` (`Simulator Contract Book`), 320 pages |
| Local backend | `127.0.0.1:8000`; runtime-only API base URL `http://127.0.0.1:8000` |
| Xcode / project | Xcode 26.5; `ios/Spine/Spine.xcodeproj`; scheme `Spine`; Debug |
| Simulator | iPhone 17, iOS 26.5, UDID `7990CE55-B413-4CCC-8F92-45FD2A33CF32` |
| App / derived data | `com.armaan.Spine`; `ios/.derivedData` |
| Browser mirror | `http://localhost:3200`; real, updating simulator frame verified |
| Authentication | A disposable local account authenticated successfully; identity and credentials omitted |

## Preflight and evidence controls

- [x] The objective and current BK laws were reviewed before implementation and again before acceptance.
- [x] A new disposable database was used; no persistent or production database was read or mutated during the acceptance run.
- [x] All migrations ran against the disposable database and deterministic 320-page book fixture.
- [x] The backend was local-only, and the API URL was injected into the simulator process at runtime rather than checked into release configuration.
- [x] The configured iPhone 17 launched the current build and authenticated against the disposable backend.
- [x] The browser mirror displayed the same live simulator frame and updated as native UI state changed.
- [x] API evidence excluded headers/tokens; ORM projections excluded account identity and credentials.
- [x] Initial state was untracked with no journey, progress, diary, rating, or heart data.

The acceptance run exercised the canonical action endpoint at `/api/v1/tracking/manual/book/sim-book-contract/actions/<action>/`, progress at `/progress/`, atomic completion at `/complete/`, journey mutation at `/journeys/<id>/`, and diary mutation at `/api/v1/diary/<id>/`. Successful writes returned canonical state (`200`) or an intentionally empty success (`204`); validation and stale-state paths use typed `400` and `409` responses. Sanitized ORM projections were compared after each material mutation.

## Scenario results

| Scenario | Result | Observed UI and sanitized API/ORM evidence |
| --- | --- | --- |
| S1 — Untracked → To Read → remove | PASS | Plus sheet showed all book actions. To Read appeared on exactly one shelf; `PATCH 200`, then `DELETE 204`. No journey, progress, or diary rows remained. |
| S2 — Mark Read → undo | PASS | Eye created current Read with one undated read and no journey/log; undo returned `204` and restored untracked state. |
| S3 — Heart/rate implies Read | PASS | Heart and exact 4.5-star rating each implied Read while untracked. Removing either value retained Read; community display used the same five-star scale. |
| S4 — Start at zero | PASS | Currently Reading created one active journey at zero with local-today start date. A reread start used the same zero-progress rule. |
| S5 — Page and percent progress | PASS | Page entry saved 96/320; percent entry round-tripped through the same journey with canonical derived values and no premature completion. |
| S6 — Pause and resume | PASS | Pause and Resume reused the same journey and preserved 96 pages exactly. |
| S7 — Restart | PASS | Confirmed restart closed the old journey as DNF at 96 pages and created exactly one new zero-progress active journey. |
| S8 — Live DNF | PASS | DNF preserved final progress and appeared in dated reading history. No diary/completion activity or read count was added. |
| S9 — Delete DNF | PASS | Deleting the newer DNF removed only that journey and restored the exact prior 96-page journey state. |
| S10 — Delete active journey | PASS | Confirmed active-journey deletion restored the prior DNF state; the generic removal path did not erase real history. |
| S11 — Finish below final progress | PASS | Finish opened the composer with current rating/heart prefilled; save forced 320/320 and linked exactly one log to the same journey. |
| S12 — Reach 100 and dismiss | PASS | Saving 100% persisted progress first and opened the composer. Dismiss left the journey active at final progress with no completion or log. |
| S13 — Save exactly once | PASS | Saving from the final-progress journey produced one completed journey and one linked diary row; guarded retry did not duplicate either. |
| S14 — Complete reread | PASS | A later completion was derived as a reread from earlier read history; DNF history alone did not affect reread truth. |
| S15 — Presentation reread toggle | PASS | Editing the log hid its presentation reread marker and persisted the title while derived reread truth, history, and counts remained unchanged. |
| S16 — Direct completion | PASS | Log without a live journey atomically created one completed journey plus one linked diary row; opening/cancelling caused no mutation. |
| S17 — Out-of-order completion | PASS | A July 8 historical completion inserted successfully and sorted by user completion date rather than creation order. |
| S18 — Owner edit/delete | PASS | Profile → list → book → logs exposed owner Edit/Delete controls. Editing the historical log updated its presentation without corrupting journey identity. |
| S19 — Rating provenance | PASS | Manual current 3.0 stayed independent when the source log changed to 5.0. Setting current to match reattached provenance, after which a source change to 4.0 propagated to current. |
| S20 — Latest deletion/restoration | PASS | Deleting the current direct log restored the latest live completion; deleting that completion reopened the exact prior active journey at 100%. |
| S21 — Older deletion | PASS | Deleting the older remaining completion left the restored active journey and all unrelated current state unchanged. |
| S22 — Active deletion with mixed history | PASS | Deleting the active journey restored DNF at 96 pages while an independent undated Read remained visible and contributed one lifetime read. |
| S23 — Five shelf transitions | PASS | The same record transitioned through DNF, Read, To Read, Currently Reading, and Paused; each state appeared on exactly one shelf and disappeared from the previous shelf. |
| S24 — Cold relaunch convergence | PASS | After process stop/relaunch, Home, Library, Profile, nested detail, history, rating, and counts converged on Paused with DNF 96-page history, one undated lifetime read, 4.5 stars, and no diary rows. |

Final sanitized ORM projection: current status `Paused`, score `9.0` (4.5 stars), one current zero-progress paused journey, one prior DNF journey at 96/320, one independent undated Read fact, zero diary rows, and one lifetime read. This matched the cold-relaunched native UI and live browser mirror.

## Defects discovered and closed during acceptance

| Defect | Resolution and retest |
| --- | --- |
| Undo Read returned `200` with an empty body, which the iOS repository attempted to decode. | Empty success is now `204`; the repository has an explicit undo route and regression test. S2 and the focused/full iOS suites passed. |
| Book community ratings were scaled twice and could render values such as 9.0/5. | Community average/distribution now consume the shared half-star contract. Backend assertions and simulator display passed at 4.5/5 and after provenance edits. |
| Owner Edit/Delete controls were missing when detail was opened through a profile list or nested diary surface. | Current-user identity is propagated through both navigation paths. S18 and the full iOS suite passed. |

Open acceptance defects: **none**.

## Automated and build verification

| Check | Result |
| --- | --- |
| Focused backend contract, migration, and shared-weight suites | 31 tests passed |
| Full Django suite | 1,135 tests passed; 32 intentional skips |
| Django system check | Passed, no issues |
| Migration drift check | Passed, no changes detected |
| Ruff | Passed: `ruff check src` |
| Diff whitespace check | Passed |
| Focused iOS book contract suite | 8 tests passed |
| Full iOS scheme on iPhone 17 | 333 tests passed; 0 failed; 0 skipped |
| iPhone 17 simulator build and authenticated launch | Passed |
| Native browser mirror / cold relaunch | Passed |

Final acceptance: **34/34 numbered BK laws Verified; 24/24 simulator scenarios Passed.** Existing movie and music behavior remained green. No deployment, push, checked-in credential, or production mutation was performed.
