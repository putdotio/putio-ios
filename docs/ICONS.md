# Icon system

Product interface glyphs use [Phosphor Icons](https://github.com/phosphor-icons/core), matching the public put.io design system. The iOS app owns its native adapter and checks a selected set of official SVG assets into `Putio/Assets.xcassets/Phosphor` so builds never depend on the network.

## Visual contract

- Use regular-weight Phosphor icons in neutral gray by default
- Use fill weight for selected or active states
- Keep the intrinsic SVG canvas at 16 points and scale it with UIKit view constraints where a larger control needs it
- Keep the filled folder yellow as the signature file-browser icon
- Keep save-to-put.io, download-to-device, and stream/play as distinct metaphors
- Do not replace brand artwork, app icons, media artwork, or other non-glyph imagery with Phosphor

## Updating assets

`Config/PhosphorIcons.json` pins the upstream npm tarball, its Subresource Integrity checksum, and the selected icon names and weights. Generated asset catalogs and source hashes are recorded in `Config/PhosphorIcons.lock.json`.

1. Edit the selected icon list in `Config/PhosphorIcons.json`
2. Run `make icons-sync`
3. Inspect the generated SVG image sets and lock-file diff
4. Run `make verify`

`make icons-verify` is offline and fails when generated assets, their metadata, the lock file, or the checked-in MIT license drift from the manifest. `make verify` runs this check before building the app.

Phosphor Icons is distributed under the MIT license. The pinned upstream license is checked in at `ThirdParty/PhosphorIcons/LICENSE`.
