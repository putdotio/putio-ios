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
- `mise run test`
- `mise run build`
- `mise run verify`
- `mise run open`

## Workflow

- Run `mise run bootstrap` in a fresh checkout or worktree
- Run `mise run verify` before handoff
- Change targets and settings in `Project.swift`, never in generated Xcode files
- Use Swift Package Manager for dependencies
- Keep platform-specific UI, lifecycle, focus, playback, and download behavior in the matching app shell
- Put only genuinely cross-platform models, session, API, and feature logic in `PutioCore`
- Keep checked-in defaults open-source-safe and require no account, token, or secret for generation and verification

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
