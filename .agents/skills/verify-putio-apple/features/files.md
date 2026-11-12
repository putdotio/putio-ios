# Files

A signed-in user browses Your Files, sorts and searches them, creates, renames,
moves, and trashes items one at a time or in bulk, manages Trash, previews
images and documents, and opens put.io links into the same screens.

## Sub-features

- `folder-header` shows each folder's item count and size, and Back keeps the
  parent's place.
- `browse-sort` changes the folder sort from the browse menu and appends the
  next page on scroll.
- `search` pages results, retries a failed page, and restores the open folder
  after a relaunch.
- `row-menus` lists each item kind's long-press rows in order, marks watched
  and unwatched with a seeded failure, swipes both ways, and shows Open in VLC
  only with VLC installed.
- `file-actions` creates a folder, rolls back a failed rename, retries it from
  the toast, moves by context menu and swipe, and trashes by swipe.
- `move-sheet` walks the move sheet's folder levels, keeps it open on a taken
  name, disables the current folder and a folder inside the moved one, and
  moves into a folder made in the sheet.
- `bulk` selects all, deselects, ends selection, moves with partial-failure
  retry, and trashes with batch retry.
- `trash-disabled` deletes permanently, with copy that says so, when the account
  has Trash off.
- `trash` restores, retries, deletes, and empties Trash.
- `reconcile` updates other tabs after an open folder is renamed or deleted.
- `previews` shows images and PDFs, reports unsupported files, and hands video
  to VLC when it is installed.
- `deep-links` opens links cold, warm, and signed out.
- `large-text` keeps long names, selection, and the download picker usable at
  the largest text size.

## How to get to it (user POV)

- Files tab: rows open folders and files; the `More` menu (`files.menu`) holds
  Select, New folder, and sort. iOS 27 drops menu item identifiers; find them
  by label.
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
  appends without a tap; Name descending puts `Document.pdf` first. Screenshot:
  `runtime-sorted-root`.
- **Search.** Run `--only search-restoration`. A failed second page offers
  retry, results append, and a relaunch reopens Harness Folder until sign-out.
  Screenshot: `runtime-search-results`.
- **Item menus.** Run `--only row-menus`. The first Mark as unwatched on
  `S04E02` (442) fails and rolls back. Screenshots: `runtime-item-swipe-left`,
  `runtime-item-menu-folder`, `runtime-item-swipe-right`, `runtime-item-menu-vlc`.
- **File actions and bulk.** Run `--only file-actions`. The first rename fails
  and rolls back, Try again on the toast applies it, and bulk Trash fails once,
  then moves both items on retry. Screenshots: `runtime-rename-failed-toast`,
  `runtime-file-actions`.
- **Move sheet.** Run `--only move-sheet`. Moving `Blue.Lights.S04E01.en.srt`
  (445) into Harness Folder fails as a taken name; `--putio-harness-hold-move-folders`
  holds the sheet's Harness Folder listing. Screenshot: `runtime-move-name-taken`.
- **Trash off.** Run `--only trash-disabled`. The context menu says Delete, and
  the confirmation says the item cannot be restored.
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
- `files.selection.toggle` is Done in the toolbar while editing.
- Rename and New folder are system alerts: find them with `app.alerts[title]`
  and type once the keyboard shows; Rename selects the stem first.
- Some fixture responses are delayed on purpose, such as a failed rename (5 s)
  and a Trash restore (3 s). Wait on the visible result.
