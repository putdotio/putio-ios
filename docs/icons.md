# Icon system

Product glyphs use [Phosphor Icons](https://github.com/phosphor-icons/core),
like the put.io design system. A pinned set of official SVGs is checked into
`Putio/Assets.xcassets/Phosphor`, so builds never fetch icons.

## Visual contract

- Regular weight in neutral gray by default; fill weight for selected or active
  states.
- Keep the SVG canvas at 16 points; scale it with UIKit constraints where a
  larger control needs it.
- The filled yellow folder stays the file-browser signature icon.
- Save-to-put.io, download-to-device, and stream/play stay distinct metaphors.
- Brand artwork, app icons, media artwork, and other non-glyph images (logo,
  offline illustration, disco ball, slider thumb) stay outside Phosphor.

## App icons

The 1024×1024 marks come from `@putdotio/design/assets/*`:

| Catalog          | Asset                        | Channel              |
| ---------------- | ---------------------------- | -------------------- |
| `AppIconDev`     | `app-icon-dev-blueprint.png` | local / `io.put.dev` |
| `AppIconNightly` | `app-icon-nightly-stars.png` | TestFlight           |
| `AppIcon`        | `app-icon-prod-dark.png`     | App Store            |

## Updating glyphs

[`Config/PhosphorIcons.json`](../Config/PhosphorIcons.json) pins the upstream
npm tarball, its integrity checksum, and the selected names and weights;
`Config/PhosphorIcons.lock.json` records the generated catalogs and hashes.

1. Edit the icon list in `Config/PhosphorIcons.json`.
2. Run `mise run icons-sync`.
3. Inspect the generated image sets and the lock-file diff.
4. Run `mise run verify`.

`mise run verify-icons` runs offline inside `verify-fast`. It fails when the
assets, their metadata, the lock file, or the MIT license at
`ThirdParty/PhosphorIcons/LICENSE` drift from the manifest, and it rejects SF
Symbol call sites and legacy icon catalogs.
