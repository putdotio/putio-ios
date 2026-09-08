<div align="center">
  <p>
    <img src="https://static.put.io/images/putio-boncuk.png" width="72" alt="put.io boncuk">
  </p>

  <h1>putio-ios</h1>

  <p>Native put.io apps for iOS, watchOS, and tvOS</p>
</div>

## Overview

The `next` generation is a Tuist-generated SwiftUI workspace with three thin app shells and one shared Swift package:

- `Apps/iOS`
- `Apps/watchOS`
- `Apps/tvOS`
- `Packages/PutioCore`

The shipping legacy application remains on the protected `main` branch while the rewrite develops on `next`.

`PutioCore` carries the generated design-token adapter and the shared component kit. Design direction lives in [DESIGN.md](./DESIGN.md): native platform elements with put.io theming, never ports of web component recipes.

## Setup

Install [mise](https://mise.jdx.dev), then run:

```bash
mise install
mise run bootstrap
```

No Tuist account, application secret, or signing material is required. Bootstrap also downloads the licensed GT America and Berkeley Mono fonts into the ignored `Resources/BrandFonts` directory; see [Contributing](./CONTRIBUTING.md#setup) for the manifest and repair commands.

## Commands

```bash
mise run generate     # regenerate Putio.xcworkspace without opening Xcode
mise run open         # regenerate and open the workspace
mise run tokens       # regenerate the committed Swift design-token adapter
mise run fonts-setup  # provision the checksummed licensed fonts
mise run test         # tooling tests, swift-format lint, PutioCore and harness tests
mise run build        # build all three app shells
mise run verify       # generate, doctor, test, build, and both snapshot suites
mise run harness      # typed headless simulator harness (`-- help`)
```

## Design tokens

`PutioCore` exposes the generated `PutioTheme` API consumed by every app shell. The dark-only adapter emits semantic Swift roles plus a semantic color asset catalog from the exact `@putdotio/design` version in `pnpm-lock.yaml`. Change tokens through the procedure in [Contributing](./CONTRIBUTING.md#design-tokens).

The raw spacing scale remains fixed. Content-coupled gaps and meaningful interface icons use generated `PutioMetricRole` values with an explicit Dynamic Type text style; structural layout, overscan, radii, borders, and minimum interaction geometry do not scale implicitly.

Semantic typography roles resolve to the bundled GT America faces on every shell. Berkeley Mono is
available only to iOS and watchOS; tvOS has no mono role or mono font resource. System fallback remains
active per glyph for filenames outside the brand fonts character repertoire.
Semantic numeric roles use tabular figures: Berkeley Mono on iOS and watchOS, and GT America with
OpenType tabular figures on tvOS.

## Development identities

- iOS: `io.put.dev.ios`
- watchOS companion: `io.put.dev.ios.watchkitapp`
- tvOS: `io.put.dev.tvos`

Production identities and delivery lanes are tracked separately.

## Sign-out recovery

If removing saved credentials or revoking the session fails, the app reports that
sign-out did not finish and offers a retry. It blocks restoring or starting a
session in that app instance until sign-out succeeds. If both operations fail,
closing and reopening the app can still restore the retained token; finish the
retry before closing the app. Sign-out intent is not persisted separately.

## Docs

- [Apple Platform Harness](./docs/HARNESS.md)
- [Distribution](./docs/DISTRIBUTION.md)
- [Security](./SECURITY.md)

## Contributing

See [Contributing](./CONTRIBUTING.md) for local setup, verification, and runtime proof.

## License

This project is available under the [MIT License](./LICENSE)
