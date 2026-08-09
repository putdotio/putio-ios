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
mise run open      # regenerate and open the workspace
mise run test      # format-check and test PutioCore
mise run build     # build all three app shells
mise run verify    # test PutioCore and build all three app shells
```

## Development identities

- iOS: `io.put.dev.ios`
- watchOS companion: `io.put.dev.ios.watchkitapp`
- tvOS: `io.put.dev.tvos`

Production identities and delivery lanes are tracked separately.

## License

This project is available under the [MIT License](./LICENSE)
