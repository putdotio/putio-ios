# iOS Visual Reference

A local gallery of the committed snapshot baselines, for design review and
store-asset prep. It is not the regression suite: `mise run verify` and
`mise run e2e-simulator` pixel-compare the same images.

```sh
mise run vref            # copy baselines, refresh the manifest, write index.html
mise run vref-serve      # the above, then serve it locally
mise run verify-vref     # regenerate, then check the manifest and every asset
```

Each command regenerates first, so all three work on a fresh clone.

## What is committed

Only `manifest.json` and this README. `screenshots/` and `index.html` are
ignored: `mise run vref` encodes the baselines under `PutioUITests/__Snapshots__/`
and `PutioTests/__Snapshots__/` to lossless webp. The baselines are the single
source of truth, so a second committed copy could drift from what CI asserts.

## Editing the manifest

`mise run vref` rewrites only the mechanical fields: `file`, `group`,
`platform`, `device`, `viewport`, `sizeBytes`, and the top-level `updatedAt`.
`file` and `sizeBytes` describe the webp, not the source baseline. You own the
curated fields:

- `title`: the screen's name
- `tags`: the filter rows
- `notes`: what a reviewer should look at
- `capturedAt`: when the baseline was recorded

`capturedAt` is written once. A new entry without one gets the baseline's last
commit author date, or the current time if it is uncommitted. It is never
recomputed, because every squash merge writes a new author date.

A baseline without a manifest entry fails the sync, and so does an entry
without a baseline. Both errors name the id.

## Rules

The baselines live in a public repository, so everything here must be
public-safe.

- Images come from `PUTIO_E2E_MOCK_API` fixtures, never a real account: no real
  usernames, file names, content ids, tokens, or local IPs.
- Record with the brand fonts installed (`mise run fonts-setup`).
- Screens come from the pinned iPhone 17 Pro Max (1320x2868); components render
  in unit tests at their own sizes. Everything is dark mode.
