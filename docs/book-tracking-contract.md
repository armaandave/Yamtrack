# Book Tracking Contract

Status: **working contract; accepted baseline only**

Last reviewed: **2026-07-20**

This document defines library status, direct status assignment, live reading,
progress, completion, and diary behavior for books in Spine. It is not yet
implementation-ready. Unresolved behavior will be decided through product
interview and added only after acceptance.

The single-weight contract remains authoritative for movies and music. Books
use the same media-detail interaction language where it fits, but completion
must coexist with progress and non-completion statuses.

## Terminology

| Term | Meaning |
| --- | --- |
| Tracking | The user's current library relationship with one book. |
| Status | The book's current library section. |
| Journey | A live attempt that begins when the user starts reading and may be paused, resumed, dropped, or completed. |
| Progress update | A saved page or percentage position during a journey. |
| Completion log | The diary entry created when a live journey is finished and its log composer is saved. |
| Direct status assignment | Placing a book in a library section without claiming when the state occurred. |
| Mark as Read | Directly record that the book was completed sometime in the past without starting a journey or creating a diary entry. |

## Canonical statuses and library sections

### BK-001: Every status is a library section

Book tracking has exactly one current status:

- Planning;
- In Progress, displayed as Currently Reading;
- Paused;
- Dropped, displayed to readers as Did Not Finish or DNF; or
- Completed, displayed as Read where appropriate.

Every tracked book appears in the corresponding section of the Books library.
Changing status moves the existing tracking record between sections; it does
not duplicate the book.

Only the current status determines library placement. Historical outcomes do
not duplicate the book across sections. For example, a previously completed
book whose later reread was dropped appears only in DNF; its earlier completion
remains in diary and read history.

Custom lists, ownership, favorites, and other organization are independent of
the status sections.

### BK-002: Library membership follows tracking

Assigning any book status creates or updates its one tracking record and places
the book in the library. Removing tracking removes it from the status sections
but must not silently remove custom-list membership or historical diary data.

## Direct status assignment

### BK-100: The media-page plus control exposes status actions

The book media page uses the same bottom action rail pattern as movies. The plus
control opens book actions rather than only a diary composer.

It provides actions for:

- Currently Reading;
- Paused;
- Did Not Finish;
- Read or Log; and
- Planning where that action is presented in the shared media-page pattern.

These base options remain visible regardless of current status. The current
status is displayed as selected or disabled rather than as a duplicate action.
When the book is Paused, the menu additionally offers Resume. Mark as Read
remains on the eye rather than appearing in this menu.

### BK-101: Retrospective status assignment does not invent history

Planning, Paused, Dropped, and Completed may be assigned directly so a user can
reconstruct their library after joining Spine.

Direct assignment:

- changes the current library section;
- creates no diary entry;
- invents no progress, start date, end date, or status date; and
- does not claim that the state change happened today.

For example, a user may place a book they abandoned before installing Spine in
the DNF section without creating a dated journey or log.

### BK-102: Mark as Read mirrors undated Mark Watched

Mark as Read records only that the user completed the book at least once before
tracking it in Spine.

It:

- assigns Completed;
- adds the book to the library;
- creates no live journey;
- creates no diary entry;
- records no completion date; and
- does not create multiple historical reads when invoked repeatedly.

Mark as Read is not the interface for entering multiple past reads. It is the
book equivalent of marking a movie watched without logging it.

When a real Currently Reading or Paused journey exists, tapping the eye does
not perform an undated Mark as Read. It opens that journey's completion composer
and follows BK-401. When no live or paused journey exists, the eye performs the
normal undated Mark as Read action.

Tapping the filled eye cannot remove Read while any completion log exists. The
UI must tell the user to delete the completion logs first. If Read exists only
through undated Mark as Read, the filled eye removes that undated completion and
clears its current rating and title-level heart under the movie cleanup rules.

### BK-103: Currently Reading starts live tracking

Choosing Currently Reading represents reading the book now rather than
reconstructing an old library state. It starts or establishes the live journey
used by progress tracking.

Choosing Currently Reading from Completed creates a new journey at zero,
defaults its start date to the user's current local date, and displays it as
Rereading. Previous completions and logs remain unchanged. Completing the new
journey creates another completion log.

Mark as Read remains limited to one undated completion fact and is not used to
create repeated historical reads.

### BK-104: Direct Log creates a dated completed journey

When no active or paused journey exists, plus to Log opens the standard
completion composer. Saving atomically creates a completed journey and its
dated completion log, then moves the book to Completed. Cancelling or a failed
save changes nothing.

If an earlier completed journey exists, the new completed journey is a reread.
Direct Log and finishing a live journey are the only flows that create
additional completed reads.

### BK-105: Log finishes an existing active or paused journey

When a real Currently Reading or Paused journey exists, plus to Log opens the
completion composer for that journey. Saving completes that same journey and
links its existing progress to the new completion log; it must not create a
separate journey.

A retrospectively assigned Paused book without a journey follows BK-104.

### BK-106: Logging after DNF preserves the closed attempt

When a real DNF journey exists, plus to Log does not convert or delete it.
Saving creates a separate completed journey and completion log under BK-104.

The new completion is a reread only if a journey was Completed before it. A DNF
journey alone does not make a later completion a reread.

## Rating and heart controls

### BK-200: Hearting follows the movie interaction model

Hearting a book implies that the user has read it, just as hearting a movie
implies watched. When no live or paused journey exists, activating the heart:

- performs undated Mark as Read;
- moves the book to Completed;
- sets the title-level heart; and
- may present the same optional rating picker used by the movie rail.

Dismissing the optional rating picker preserves both Read and hearted state.
Unhearting alone removes the title-level heart without removing Read status.

The required behavior when a live or paused journey exists is resolved in a
following law because that journey cannot be completed without its log.

### BK-201: Hearting a live or paused journey completes through its log

When a real Currently Reading or Paused journey exists, activating the empty
heart opens that journey's completion composer with heart selected. Saving
atomically:

- sets the title-level heart;
- completes the existing journey;
- creates its completion log; and
- moves the book to Completed.

Cancelling or a failed save leaves the journey, status, progress, and heart
unchanged.

### BK-202: Completion ratings and hearts reuse single-weight provenance

Book completion logs follow the current-versus-diary rating and heart source
laws in the Single-Weight Consumption Contract:

- every completion log preserves its own historical rating and heart;
- a newly saved completion log becomes the current rating and heart source;
- editing the source log updates current state;
- directly changing current state decouples it from existing logs;
- editing a non-source log never changes current state; and
- a later completion log recouples current state.

Deleting a completion log applies both those provenance laws and the journey
restoration laws in this contract.

## Live journey and progress

### BK-300: Progress belongs to the live journey

The existing book progress system remains the foundation. A live journey owns
the user's page or percentage updates. Pausing, resuming, dropping, and
finishing operate on that same journey rather than creating unrelated tracking
records.

### BK-301: Progress UI exposes journey status actions

The update-progress screen provides direct actions to:

- pause the active journey;
- mark it Did Not Finish; and
- finish the book.

Resuming a paused book returns it to Currently Reading and continues its saved
progress rather than resetting it.

### BK-302: Pausing preserves progress

Pausing moves the book to the Paused library section and preserves its current
progress. Resume returns it to Currently Reading with that progress intact.

If Paused was assigned retrospectively and no journey exists, Resume creates a
new live journey at zero progress and defaults its start date to the user's
current local date.

### BK-303: Dropping preserves progress

Marking a live journey Did Not Finish moves the book to the DNF library section
and preserves the progress reached before it was dropped.

DNF permanently closes that journey. Choosing Currently Reading later creates a
new journey at zero progress with a start date defaulting to the user's current
local date. The closed journey and its progress remain historical and are not
carried into the new journey.

The new journey is not a reread unless at least one earlier journey was
Completed.

## Journey completion and diary

### BK-400: Finishing a live journey requires the log composer

When the user finishes a journey, Spine opens the standard book log composer so
the user can supply the completion date, rating, heart, review, and other diary
fields.

Successfully saving the composer must atomically:

- complete the live journey;
- move the book to the Completed library section;
- create exactly one completion diary entry; and
- keep the completion and diary linked as one event.

The composer:

- requires a completion date defaulted to the user's current local date;
- rejects future dates;
- prefills rating and heart from current title state;
- automatically marks reread when an earlier completed journey exists; and
- saves visible prefilled values even when their controls were untouched.

### BK-401: Journey completion is atomic with log creation

Opening the finish composer does not change tracking. If the user dismisses the
composer or its save fails:

- the journey remains active;
- the book remains Currently Reading;
- progress remains unchanged; and
- no completion diary entry is created.

The journey becomes Completed only when its completion log saves successfully.

### BK-402: Direct completion and journey completion are different flows

- Mark as Read creates undated Completed tracking without a journey or log.
- Finishing a journey creates Completed tracking through a required completion
  log.

The UI and persistence layer must preserve this distinction.

### BK-403: Deleting a live-journey completion log reopens the journey

Deleting the completion log that finished a real journey removes that completed
read and restores the journey's exact pre-finish state:

- a journey finished from Currently Reading returns to Currently Reading;
- a journey finished from Paused returns to Paused; and
- all progress updates remain intact.

The completion log and journey completion are coupled in both directions.

### BK-404: Deleting a direct completion log restores prior tracking

Deleting a completion created by direct Log removes the completed journey that
was created with it and restores the exact status that existed before logging.

If the book was previously untracked and no other completion or historical
journey remains, deletion removes it from the library. Remaining history or
undated completion evidence continues to determine its status under this
contract.

## Cross-surface consistency

### BK-500: Status and progress agree everywhere

After a successful mutation, media detail, book library sections, progress UI,
diary, profile, and activity surfaces must agree about:

- current status;
- library membership;
- current progress;
- whether a live journey exists; and
- whether a completion log exists.

Opening the same progress or log editor from different surfaces must not change
its domain behavior.

## Contract change policy

Numbered laws are normative only where they state resolved behavior. Sentences
that explicitly say behavior remains to be finalized are not implementation
instructions. New decisions from the product interview must update this
contract before implementation begins.
