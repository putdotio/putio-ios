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

## Setup

Install [mise](https://mise.jdx.dev), then run:

```bash
mise install
mise run bootstrap
```

No Tuist account, application secret, or signing material is required.

## Commands

```bash
mise run generate  # regenerate Putio.xcworkspace without opening Xcode
mise run tokens    # regenerate the committed Swift design-token adapter
mise run open      # regenerate and open the workspace
mise run test      # format-check and test PutioCore
mise run build     # build all three app shells
mise run verify    # test PutioCore and build all three app shells
```

## Design tokens

`PutioCore` exposes the generated `PutioTheme` API consumed by every app shell. The adapter emits semantic Swift roles plus an adaptive color asset catalog from the exact `@putdotio/design` version in `pnpm-lock.yaml`; `mise run verify` rejects unclassified upstream tokens and stale generated output. Change token values in the design-system repository, bump the package here, audit `scripts/design-token-coverage.json`, then run `mise run tokens`.

The raw spacing scale remains fixed. Content-coupled gaps and meaningful interface icons use generated `PutioMetricRole` values with an explicit Dynamic Type text style; structural layout, overscan, radii, borders, and minimum interaction geometry do not scale implicitly.

## Development identities

- iOS: `io.put.dev.ios`
- watchOS companion: `io.put.dev.ios.watchkitapp`
- tvOS: `io.put.dev.tvos`

Production identities and delivery lanes are tracked separately.

## Docs

- [Apple Platform Harness](./docs/HARNESS.md)
- [Security](./SECURITY.md)

## Contributing

See [Contributing](./CONTRIBUTING.md) for local setup, verification, and runtime proof.

## License

This project is available under the [MIT License](./LICENSE)
