# Files

A signed-in user browses Your Files, sorts and searches them, creates, renames,
moves, and trashes items one at a time or in bulk, manages Trash, previews
images and documents, and opens put.io links into the same screens.

## Sub-features

- `folder-header` shows each folder's item count and size, and Back keeps the
  parent's place.
- `continue-watching` lists a video played to the middle on the root, removes
  it from its menu, lists no finished video, and drops a trashed one.
- `browse-sort` changes the folder sort from the sort button and appends the
  next page on scroll.
- `recent-searches` keeps the last five submitted searches, runs, removes and
  clears them, hides them while history is off, and keeps them on a failed write.
- `search` pages results, retries a failed page, and restores the open folder
  after a relaunch.
- `row-menus` lists each item kind's long-press rows in order, marks watched
  and unwatched with a seeded failure, swipes both ways, and shows Open in VLC
  only with VLC installed.
- `file-actions` creates a folder, rolls back a failed rename, retries it from
  the toast, moves by context menu and swipe, and trashes by swipe.
- `exclusive-link`, `exclusive-link-refused`, `exclusive-link-failed`, and
  `exclusive-link-cancel` create a link for a file and a folder, copy and share
  it, show every refusal and a failure with Try again, cancel on close, and
  find the new links on Account.
- `move-sheet` walks the move sheet's folder levels, keeps it open on a taken
  name, disables the current folder and a folder inside the moved one, and
  moves into a folder made in the sheet.
- `bulk` selects all, ends selection, moves with partial-failure retry, and
  trashes with batch retry.
- `selection-bar` changes the bar's actions as videos, audio, and a folder join
  the selection, and selects only the loaded page of a 450-file folder.
- `selection-trash-off` deletes after a confirm, and reports the one video that
  refuses a bulk Watched.
- `bulk-results` trashes three episodes and restores them with Undo, then marks
  three watched; both leave selection.
- `trash-disabled` deletes permanently, with copy that says so, when the account
  has Trash off.
- `trash-undo` moves to Trash with Undo, by menu and swipe, and rolls back a
  failed move.
- `trash-limit` asks before a permanent delete when Trash refuses a folder, and
  disables Trash while the setting is unconfirmed.
- `trash` restores, retries, deletes, and empties Trash.
- `reconcile` updates other tabs after an open folder is renamed or deleted.
- `previews` shows images and PDFs, reports unsupported files, and hands video
  to VLC when it is installed.
- `preview-paging` swipes between a folder's images past a video, loads the
  folder's next page, pans instead of paging while zoomed, and shows one file
  from Search.
- `preview-more` renames and moves the shown file from the viewer's More menu,
  and shows a failed rename's toast.
- `preview-vlc` offers the App Store when VLC is gone, then hands off.
- `preview-vlc-failed` shows the failed handoff's toast for a missing download
  token and a refused handoff, then hands off on the next tap.
- `preview-trash` trashes the shown file, shows the next one with Undo, brings
  it back, and closes the viewer over the folder when it was the only file.
- `preview-delete` deletes the shown file permanently after the alert when the
  account has Trash off.
- `preview-trash-limit` asks before deleting the shown file permanently when
  Trash refuses it.
- `preview-trash-limit-late` shows the failure toast over the folder when the
  refusal arrives after the viewer closed.
- `deep-links` opens links cold, warm, and signed out.
- `large-text` keeps long names, selection, and the download picker usable at
  the largest text size.

## How to get to it (user POV)

- Files tab: rows open folders and files; the sort button (`files.sort`) holds
  Sort by, Order, and Videos; the `More` menu (`files.menu`) holds Select and
  New folder. iOS 27 drops menu item identifiers; find them by label.
- Long-press a row for its menu. Swipe right for Move; left for More,
  Download, and Trash.
- Search tab: type a query and submit.
- Account > Trash for Trash management.
- A put.io link opened from outside the app.

## Driving it with the harness

Preconditions:

- Seeded `files-browser` fixtures; the root lists `Harness Folder` (410) and
  `Root Movie.mkv` (412). New folders get IDs from 415 up. Harness Folder
  holds `Blue Lights` (440), six items with a watched episode.

- **Folder header.** Run `--only folder-header`. Screenshot:
  `runtime-folder-header`.
- **Sort and continuation.** Run `--only sort-continuation`. `Season Pack.zip`
  appends without a tap; `Z to A` puts `Document.pdf` first. Screenshot:
  `runtime-sorted-root`.
- **Sort menu.** Run `--only sort-menu`. Blue Lights walks every field and both
  orders, `Unwatched first` and `Watched first`, a failed first `Type, Z to A`,
  then a relaunch keeps the folder's order while Harness Folder keeps the
  account default.
- **Folder states.** Run `--only folder-states`.
  `--putio-harness-folder-states` adds `Empty` (423) and the 450-file
  `Paging Folder` (460), whose page 2 fails once. Screenshots:
  `runtime-folder-empty`, `runtime-folder-load-more-failed`.
- **Folder errors.** Run `--only folder-errors`.
  `--putio-harness-folder-fault <faults>@<folder id>` fails that folder's next
  listings in order, then lists it; a fault is a status code or `offline`.
  Blue Lights walks 403, 429, 503 and offline, then retries on its own; the
  offline banner shows only above finished downloads.
  Screenshots: `runtime-folder-forbidden`, `runtime-folder-offline`.
- **Search.** Run `--only search-restoration`. A failed second page offers
  retry, results append, and a relaunch reopens Harness Folder until sign-out.
  Screenshot: `runtime-search-results`.
- **Search filters.** Run `--only search-filters`. Typing `blue` sends one
  search; Videos sends `type=VIDEO`; the `search.requests` probe lists each
  search as `query|type`. `--putio-harness-hold-search` holds every search.
  Screenshot: `runtime-search-grouped`.
- **Search states.** Run `--only search-states`. `blorp` matches nothing, a
  54-character query shows cut at 50, `retry` under Videos fails once and Try
  again repeats `retry|VIDEO`. `--putio-harness-search-offline` fails every
  search offline; `--putio-harness-search-more-fails` gives `blue` a next page
  that always fails. Screenshots: `runtime-search-none`,
  `runtime-search-long-query`, `runtime-search-failed`, `runtime-search-offline`.
- **Recent searches.** Run `--only recent-searches`.
  `--putio-harness-search-history <recent|off|fail-write>` seeds the board's
  four searches; `off` turns history off and `fail-write` fails the first
  write. Without it the list starts empty. Screenshots: `runtime-search-start`,
  `runtime-search-recent`, `runtime-search-recent-failed`.
- **Item menus.** Run `--only row-menus`. The first Mark as unwatched on
  `S04E02` (442) fails and rolls back. Screenshots: `runtime-item-swipe-left`,
  `runtime-item-menu-folder`, `runtime-item-swipe-right`, `runtime-item-menu-vlc`.
- **File actions and bulk.** Run `--only file-actions`. The first rename fails
  and rolls back, Try again on the toast applies it, and bulk Trash fails once,
  then moves both items on retry. Screenshots: `runtime-rename-failed-toast`,
  `runtime-file-actions`.
- **New folder failure.** `--putio-harness-create-folder-fails-once` fails the
  first create-folder request; Try again creates the same name. Board:
  `rd-ios-81-new-folder-failed-toast`.
- **Move sheet.** Run `--only move-sheet`. Moving `Blue.Lights.S04E01.en.srt`
  (445) into Harness Folder fails as a taken name; `--putio-harness-hold-move-folders`
  holds the sheet's Harness Folder listing. Screenshot: `runtime-move-name-taken`.
- **Exclusive link.** Run
  `--only exclusive-link,exclusive-link-refused,exclusive-link-failed,exclusive-link-cancel`.
  `--putio-harness-public-link-create <ready|slow|refusals|failing>` seeds the
  create call; `refusals` returns each refusal once in turn, `failing` fails the
  first call, and `slow` never answers. Screenshots:
  `runtime-exclusive-link-created`, `runtime-exclusive-link-account`,
  `runtime-exclusive-link-refused`, `runtime-exclusive-link-failed`,
  `runtime-exclusive-link-creating`. Boards: `rd-ios-78-link-create`,
  `rd-ios-79-link-created`, `rd-ios-80-link-refused`.
- **Selection.** Run `--only selection-bar`, `--only selection-trash-off`, and
  `--only bulk-results`. `--putio-harness-bulk-trash-refusal` fails every
  multi-episode Trash. Screenshots: `runtime-selection-mixed`,
  `runtime-selection-all-loaded`, `runtime-selection-trash-off`,
  `runtime-bulk-trashed`.
- **Trash off.** Run `--only trash-disabled`. The swipe and menu say Delete
  permanently, and the alert says Trash is off.
- **Trash and Undo.** Run `--only trash-undo`. The first Trash move of
  `S04E04` (444) fails. Screenshots: `runtime-trash-undo`, `runtime-trash-failed`.
- **Trash limit and unknown setting.** Run `--only trash-limit`.
  `--putio-harness-trash-limit` refuses Harness Folder (410) for Trash;
  `--putio-harness-unconfirmed-settings` fails account loads after a settings
  save. Screenshots: `runtime-trash-limit`, `runtime-trash-unknown`.
- **Trash.** Run `--only trash-management`. Screenshots:
  `runtime-trash-refresh-error`, `runtime-trash-loaded`, `runtime-trash-empty`.
- **Reconcile tabs.** Run `--only folder-reconciliation`. Search shows the new
  name, then "Folder not found" after the delete.
- **Previews.** Run `--only previews`. Share opens the share sheet for the
  image, the PDF and the long text, from the toolbar and from the text's end
  row. Screenshots: `runtime-preview-loading`, `runtime-preview-error`,
  `runtime-preview-image`, `runtime-preview-image-landscape`,
  `runtime-preview-document`, `runtime-preview-document-middle`,
  `runtime-preview-document-landscape`, `runtime-preview-cannot-show`,
  `runtime-preview-text`, `runtime-preview-text-truncated`,
  `runtime-preview-share-image`, `runtime-preview-share-document`,
  `runtime-preview-share-text`.
- **Preview paging.** Run `--only preview-paging`. Screenshot:
  `runtime-preview-position`.
- **Preview More menu.** Run `--only preview-more`.
- **Open in VLC outcomes.** Run `--only preview-vlc,preview-vlc-failed`.
  Screenshots: `runtime-preview-vlc-missing`, `runtime-preview-vlc-failed`.
- **Preview trash.** Run `--only preview-trash`. Screenshots:
  `runtime-preview-trashed`, `runtime-preview-trashed-last`.
- **Preview delete.** Run `--only preview-delete`. Screenshots:
  `runtime-preview-more-trash-off`, `runtime-preview-delete-confirm`.
- **Preview trash limit.** Run `--only preview-trash-limit`. Screenshot:
  `runtime-preview-trash-limit`.
- **Late preview trash limit.** Run `--only preview-trash-limit-late`.
  Screenshot: `runtime-preview-trash-limit-late`.
- **Deep links.** Run `--only deep-links`. Screenshots:
  `runtime-deep-link-loading`, `runtime-deep-link-error`,
  `runtime-deep-link-folder`. Link rules live in
  [deep-link behavior](../../../../docs/deep-links.md).
- **Large text.** Run `--only accessibility-files`. Screenshots:
  `runtime-accessibility-files`, `runtime-accessibility-selection`,
  `runtime-accessibility-downloads`, `runtime-accessibility-download-picker`.

## Gotchas

- A toast's own overlay re-renders when it hides; the rest of the screen stays
  still.
- Menu items such as Select live in the toolbar menu; wait for the menu item to
  appear before you tap it.
- `selection.close` leaves selection; bar actions are
  `selection.action.<move|download|watched|unwatched|trash>`.
- Rename and New folder are drawn alerts: find them with `app.putioAlert(title)`
  and type once the keyboard shows; Rename selects the stem first.
- Some fixture responses are delayed on purpose, such as a failed rename (5 s)
  and a Trash restore (3 s). Wait on the visible result.
