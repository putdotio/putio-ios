# Agent Guide

## Repo

- Native iOS app repository for put.io
- Stack: UIKit, CocoaPods, Bundler-managed Ruby, CI-only fastlane release lanes

## Start Here

- [README.md](./README.md)
- [CONTRIBUTING.md](./CONTRIBUTING.md)
- [SECURITY.md](./SECURITY.md)

## Commands

- `make bootstrap`
- `make verify`
- `make print-simulator-destination`
- `make print-simulator-device`
- `make run-simulator`
- `make download-ios-platform`

## Rules

- Keep checked-in defaults open-source-safe
- Private service keys stay out of git
- Update docs when setup, validation, or release expectations change

## Build And Config

- Runtime config flows through `Config/Shared.xcconfig`, optional `Config/Local.xcconfig`, and `Info.plist` placeholders
- Fastlane uses the same `PUTIO_*` values from `fastlane/.env`
- Treat `fastlane/.env.example` as the contract for optional release-time config

## Local Auth And Release Flow

- `scripts/op-local-config.sh` is the only local 1Password helper
- Default shared item: `frontend-ci/putio-ios`
- `fastlane beta` and `fastlane release` are CI-only entrypoints
- Beta and release uploads use one monotonic UTC timestamp build-number strategy

## CI

- `.github/workflows/ci.yml` is verify-only and should stay aligned with `make verify`
- `.github/workflows/beta.yml` is the intentional TestFlight path
- `.github/workflows/release.yml` runs from published GitHub releases
- Use `OP_SERVICE_ACCOUNT_PUTIO_FRONTEND_CI` for shared 1Password-backed CI flows

## Simulator Notes

- Prefer `make verify` for unsigned local verification
- `make verify` prefers an advertised iPhone simulator destination on iOS `26.0+` and falls back to `iphonesimulator`
- `make run-simulator` uses the normal signed Simulator build so auth and keychain persistence match a real interactive run
- Simulator UI still depends on an installed iOS `26.x` platform and simulator runtime
