# Snapshot comparison

```bash
mise run harness -- test --platform ios
mise run harness -- test --platform tvos
mise run harness -- test --platform ios --snapshots record
```

`test` runs the platform's `snapshotSuites` from
[HarnessPlatform.configuration](../../../../Tools/PutioHarness/Sources/PutioHarnessKit/Models.swift).
[Repository verification](../../../../scripts/verify.sh) runs it too.

[SnapshotRendering.swift](../../../../Tests/Shared/SnapshotSupport/SnapshotRendering.swift)
owns baseline paths, comparison tolerance, and failure images.

- iOS rasterizes the hosted view's layer off-screen.
- tvOS 27 draws bordered controls as Liquid Glass, which off-screen layer
  rendering leaves as undefined solid fills. Both tvOS suites are app-hosted and
  capture through the render server.
- Without the brand fonts, suites render with system fallbacks and skip
  brand-baseline comparison. With `PUTIO_REQUIRE_BRAND_FONTS=1`, which CI sets
  after it installs the fonts, they fail instead.
- Each suite writes a result bundle under `build/DerivedData/Logs/Test`. `test`
  fails unless the suite ran at least one test with no failures, and with no
  skips when fonts are required.
- Gallery pages whose native layout changed in OS 27 keep a separate `-ios27` or
  `-tvos27` baseline beside the shared one.

## Record after an intentional visual change

1. Run `mise run fonts-setup`. Recording needs the brand fonts and is refused
   when `CI=true`.
2. Run `test --snapshots record`. Recording also compares against the newly
   written images.
3. Review the image diff, then commit it.

Off-screen snapshots use bordered or material fallbacks for Liquid Glass. Review
the glass itself with `screenshot --scenario gallery`.
