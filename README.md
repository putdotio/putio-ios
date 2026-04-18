<div align="center">
  <p>
    <img src="https://static.put.io/images/putio-boncuk.png" width="72" alt="put.io boncuk">
  </p>

  <h1>putio-ios</h1>

  <p>
    Native iOS app for put.io
  </p>

  <p>
    Native iOS app for put.io
  </p>

  <p>
    <a href="https://github.com/putdotio/putio-ios/actions/workflows/ci.yml?query=branch%3Amain" style="text-decoration:none;"><img src="https://img.shields.io/github/actions/workflow/status/putdotio/putio-ios/ci.yml?branch=main&style=flat&label=ci&colorA=000000&colorB=000000" alt="CI"></a>
    <a href="https://github.com/putdotio/putio-ios/blob/main/LICENSE" style="text-decoration:none;"><img src="https://img.shields.io/github/license/putdotio/putio-ios?style=flat&colorA=000000&colorB=000000" alt="license"></a>
  </p>
</div>

## Overview

`putio-ios` is the native iPhone and iPad app for put.io. The checked-in build is open-source-safe, runs without private release credentials, and uses the same local commands as CI.

Install the public app from the [App Store](https://apps.apple.com/app/id1260479699)

## Local Development

For open-source contributors, the standard workflow is:

```bash
make bootstrap
make verify
make run-simulator
```

- `make bootstrap` installs Bundler gems and CocoaPods dependencies
- `make verify` builds the unsigned app for `iphonesimulator`
- `make run-simulator` boots an available iPhone simulator on iOS `26.0+`, installs the app, and launches it
- `Config/Local.xcconfig` is the local override point for private runtime values
- `.github/workflows/ci.yml` mirrors that same OSS-safe path on pull requests and `main` pushes

For put.io teammates, the repo also supports a shared 1Password-backed flow using `frontend-ci/putio-ios` by default:

- `scripts/op-local-config.sh` to render `Config/Local.xcconfig` from one 1Password item
- `scripts/op-fastlane.sh` to load fastlane and app build settings from that same item for local beta/testflight runs
- `make op-local-config` to sync local config from the default `frontend-ci/putio-ios` item
- `make beta` to build and upload a beta using the same default item
- `make release` to build and upload a release-tagged TestFlight build from the same default item
- `.github/workflows/beta.yml` to upload a TestFlight build manually from GitHub Actions when you intentionally want one
- `.github/workflows/release.yml` to react to published GitHub releases and upload a release build from the release tag

For full setup, release-lane notes, and contributor workflow, use [CONTRIBUTING.md](./CONTRIBUTING.md)

## Requirements

- Xcode `26.x` with an installed iOS `26.x` simulator runtime
- Ruby from `.ruby-version`
- CocoaPods via Bundler

## Docs

- [CONTRIBUTING.md](./CONTRIBUTING.md) for setup, verification, and release notes
- [SECURITY.md](./SECURITY.md) for private vulnerability reporting
- [AGENTS.md](./AGENTS.md) for repo-specific agent guidance
- [fastlane/README.md](./fastlane/README.md) for generated fastlane action docs

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](./CONTRIBUTING.md) so local setup and validation stay aligned with CI

## License

This project is available under the [MIT License](./LICENSE)
