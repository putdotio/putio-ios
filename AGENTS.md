# Agent Guide

- Native SwiftUI apps for iOS, paired watchOS, and tvOS
- Tuist manifests are the canonical Xcode workspace definition
- App composition roots live under `Apps`; shared logic lives in `Packages/PutioCore`
- Generated `.xcodeproj` and `.xcworkspace` files are never committed

## Start Here

- [Overview](./README.md)
- [Contributing](./CONTRIBUTING.md)
- [Security](./SECURITY.md)

## Core Commands

- `mise run doctor`
- `mise run bootstrap`
- `mise run generate`
- `mise run tokens`
- `mise run test`
- `mise run build`
- `mise run verify`
- `mise run harness -- help`
- `mise run open`

## Workflow

- Run `mise run bootstrap` in a fresh checkout or worktree
- Run `mise run verify` before handoff
- Change targets and settings in `Project.swift`, never in generated Xcode files
- Change design tokens in `putio-design`, then bump the locked package, audit token coverage, and regenerate; never edit generated Swift or asset catalogs
- Use Swift Package Manager for dependencies
- Keep platform-specific UI, lifecycle, focus, playback, and download behavior in the matching app shell
- Put only genuinely cross-platform models, session, API, and feature logic in `PutioCore`
- Keep checked-in defaults open-source-safe and require no account, token, or secret for generation and verification
- Use the typed harness for runtime proof; do not open Simulator.app from automation
- Keep capture local by default and invoke the separate `publish` command only after reviewing the artifact

## Tuist

- Tuist is pinned in `mise.toml`
- `Tuist.swift`, `Project.swift`, and `Tuist/Package.swift` define the generated workspace
- Tuist is used locally for project generation only; hosted cache, analytics, previews, and account-backed features are out of scope
- Follow the project-local skills under `.agents/skills` when migrating or working with generated projects

## Verification Matrix

- Shared logic: `swift test --package-path Packages/PutioCore`
- Full repository: `mise run verify`
- Manifest change: regenerate, then build every app scheme
- Runtime-sensitive change: launch the affected shell in its simulator in addition to `mise run verify`
- Component or theming change: `mise run harness -- test --platform <ios|tvos>` asserts the
  committed snapshot gallery; after an intentional visual change re-record with
  `--snapshots record` and commit the image diff
- Agent runtime proof: `mise run harness -- proof --platform <ios|watchos|tvos>`

## Harness

- [Harness contract](./docs/HARNESS.md)
- Simulator devices are ephemeral, uniquely named, headless, and deleted after every command
- Deterministic proof is secret-free; live smoke uses only the `devs-fe-auto` put.io CLI profile
- Proof artifacts and provenance manifests live under ignored `build/proof/`
