# Single-Weight Consumption Simulator Verification

Date: 2026-07-17 (America/Los_Angeles)

Environment:

- iPhone 17 Simulator, iOS project scheme `Spine`
- Debug app installed from `ios/Spine/Spine.xcodeproj`
- Django development server at `http://127.0.0.1:8000`
- Runtime-only `SPINE_API_BASE_URL` override; the release base URL was not changed
- Disposable local development database and local test account
- No backend deployment and no production data mutation

The assertions below combine visible Simulator state with read-only Django ORM
checks against the same local database. Internal ratings use the existing doubled
scale, so a visible 4-star rating is stored as `8.0`.

## Required scenarios

1. **Eye consumes without logging.** On an untracked Matrix movie, tapping the
   empty eye immediately created completed tracking with
   `direct_consumption=True`, `end_date=None`, and zero diary entries. Closing
   the optional rating picker and navigating away left the eye filled.
2. **Direct rating.** The media-page rating action saved a 4-star current rating
   (`score=8.0`) with no diary source.
3. **Unwatch with no logs.** Tapping the filled eye removed Matrix tracking and
   cleared its current rating and media like.
4. **Heart consumes atomically.** Tapping the empty heart on the now-untracked
   Matrix recreated completed, undated direct tracking and the media like. Both
   remained after the optional picker was dismissed.
5. **First log is not a repeat.** A first-ever Dune: Part Two log saved with
   `is_rewatch=False`.
6. **Direct evidence defaults to repeat.** Matrix had direct consumption and no
   logs. Its new-log composer visibly opened as `LOG MOVIE` with the `Rewatch`
   control selected, current heart prefilled, and no synthetic prior date.
7. **Local date and future rejection.** New composers defaulted to Jul 17, 2026,
   the Simulator's current local date. The date picker exposed today as the
   latest selectable day; API validation of future dates is also covered by the
   contract tests.
8. **Rating and heart prefill.** New composers reflected the title's current
   rating and heart. Visible prefilled values were saved without requiring a
   second interaction.
9. **Rated Log A becomes current.** Dune Log A saved at 4 stars and became the
   current rating source (`score=8.0`).
10. **Editing a coupled source follows.** Editing Log A to 5 stars changed both
    its historical rating and current rating to 5.
11. **Direct rating decouples.** Setting the Dune title rating to 3 stars made it
    independent. Editing Log A to 2 then changed only Log A; current stayed 3.
12. **A new rated source recouples.** Log B at 4.5 stars replaced the current
    source. Editing Log B to 5 changed the current rating to 5.
13. **Heart coupling and decoupling.** A direct unlike preserved Log A's
    historical heart and decoupled current state. A new Log B prefilled the
    current heart; explicitly saving it off made current heart off and coupled
    to B. Editing B back on updated the coupled current heart.
14. **Same-day duplicates remain.** Logs A and B both existed for Dune on Jul
    17 and appeared independently in the media log list and diary.
15. **Last date uses the greatest diary date.** Editing Log A to Jul 10 while
    Log B remained Jul 17 left the title's last-consumed date at Jul 17.
16. **History blocks unwatch.** Attempting to unwatch Dune with two logs showed
    `Delete your logs before marking this as unwatched.` and preserved state.
17. **Deleting some history keeps tracking.** Deleting Log A left Log B and the
    completed Dune tracking record intact.
18. **Final diary-only evidence unwatches.** Inception was tracked only by one
    unrated, unliked diary log. Deleting it removed both its diary entry and
    tracking record.
19. **Direct evidence survives final-log deletion.** Dune also had a durable
    direct marker. Deleting its final log left completed tracking with an
    unknown date, no diary source, and zero diary entries.
20. **Music parity and language.** OK Computer used `Mark as listened`,
    `Date listened`, and `Relisten`. Direct listening created undated completed
    tracking. Its first subsequent log defaulted to relisten and saved 4 stars,
    heart on, and `is_rewatch=True`; the tracking rating/heart coupled to that
    log. Attempting to unlisten displayed the same history-blocking message.
21. **Cold relaunch and cross-surface consistency.** After stopping and
    relaunching the app with the local runtime override, Home showed the
    OK Computer listened activity, Diary showed its Jul 17 relisten, the Music
    library contained OK Computer, and media detail showed Listened, Rated 4/5,
    Logged Jul 17, 2026, and a filled heart. The Movies library also retained
    Matrix and Dune.

## Final local canonical state sampled

- Matrix: completed direct movie tracking, unknown date, no diary log.
- Dune: completed direct movie tracking, unknown date, no diary log after the
  source-deletion checks.
- Inception: no tracking and no diary history after deleting its sole
  diary-derived consumption.
- OK Computer: completed direct music tracking, one Jul 17 diary entry, 4-star
  current and diary rating, current and diary heart on, and relisten asserted.

The local test data is disposable. The app was never deployed, and the debug
localhost override was passed only to the Simulator process.
