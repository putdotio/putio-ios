# Files

A signed-in user browses Your Files, sorts and searches them, creates, renames,
moves, and trashes items one at a time or in bulk, manages Trash, previews
images and documents, and opens put.io links into the same screens.

## Sub-features

- `browse-sort` changes the folder sort from the browse menu and appends the
  next page on scroll.
- `search` pages results, retries a failed page, and restores the open folder
  after a relaunch.
- `file-actions` creates a folder, rolls back a failed rename, retries it,
  moves by context menu and swipe, and trashes by swipe.
- `bulk` selects all, deselects, ends selection, moves with partial-failure
  retry, and trashes with batch retry.
- `trash-disabled` deletes permanently, with copy that says so, when the account
  has Trash off.
- `trash` restores, retries, deletes, and empties Trash.
- `reconcile` updates other tabs after an open folder is renamed or deleted.
- `previews` shows images and PDFs, reports unsupported files, and hands video
  to VLC.
- `deep-links` opens links cold, warm, and signed out.
- `large-text` keeps long names, selection, and the download picker usable at
  the largest text size.

## How to get to it (user POV)

- Files tab: rows open folders and files; the `More` menu (`files.menu`) holds
  Select, New Folder, and sort.
- Long-press a row for Rename, Move, and Trash. Swipe right for Move, left for
  Trash.
- Search tab: type a query and submit.
- Account > Trash for Trash management.
- A put.io link opened from outside the app.

## Driving it with the harness

Preconditions:

- Seeded `files-browser` fixtures; the root lists `Harness Folder` (410) and
  `Root Movie.mkv` (412). New folders get IDs from 415 up.

- **Sort and continuation.** Run `--only sort-continuation`. `Season Pack.zip`
  appends without a tap; Name descending puts `Document.pdf` first. Screenshot:
  `runtime-sorted-root`.
- **Search.** Run `--only search-restoration`. A failed second page offers
  retry, results append, and a relaunch reopens Harness Folder until sign-out.
  Screenshot: `runtime-search-results`.
- **File actions and bulk.** Run `--only file-actions`. The first rename fails
  and rolls back, the retry applies, and bulk Trash fails once, then moves both
  items on retry. Screenshot: `runtime-file-actions`.
- **Trash off.** Run `--only trash-disabled`. The context menu says Delete, and
  the confirmation says the item cannot be restored.
- **Trash.** Run `--only trash-management`. Screenshots:
  `runtime-trash-refresh-error`, `runtime-trash-loaded`, `runtime-trash-empty`.
- **Reconcile tabs.** Run `--only folder-reconciliation`. Search shows the new
  name, then "Folder not found" after the delete.
- **Previews.** Run `--only previews`. Screenshots: `runtime-preview-image`,
  `runtime-preview-document`, `runtime-preview-error`,
  `runtime-preview-unsupported`, `runtime-vlc-missing`.
- **Deep links.** Run `--only deep-links`. Screenshots:
  `runtime-deep-link-loading`, `runtime-deep-link-error`,
  `runtime-deep-link-folder`. Link rules live in
  [deep-link behavior](../../../../docs/deep-links.md).
- **Large text.** Run `--only accessibility-files`. Screenshots:
  `runtime-accessibility-files`, `runtime-accessibility-selection`,
  `runtime-accessibility-downloads`, `runtime-accessibility-download-picker`.

## Gotchas

- A success toast stays 3 seconds. Its own overlay re-renders when it hides; the
  rest of the screen stays still.
- Menu items such as Select live in the toolbar menu; wait for the menu item to
  appear before you tap it.
- `files.selection.toggle` is Select inside the menu and Done in the toolbar
  while editing.
- Some fixture responses are delayed on purpose, such as a failed rename (5 s)
  and a Trash restore (3 s). Wait on the visible result.
