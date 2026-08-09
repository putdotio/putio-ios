# Contributing

## Requirements

- Xcode 26.x
- iOS, watchOS, and tvOS 26.x Simulator components matching the selected Xcode release
- [mise](https://mise.jdx.dev)

## Setup

```bash
mise install
mise run bootstrap
```

Bootstrap validates Xcode, installs the pinned Tuist release through mise, resolves package dependencies, and generates `Putio.xcworkspace`. It requires no Tuist login or private configuration.

## Development

Edit `Project.swift` when changing the Xcode graph. Generated Xcode projects and workspaces are disposable and ignored by Git.

```bash
mise run generate
mise run open
```

Source changes inside existing `buildableFolders` appear without regenerating. Regenerate after manifest or dependency-graph changes.

## Verification

```bash
mise run verify
```

This runs the `PutioCore` tests and builds the iOS, watchOS, and tvOS schemes against generic simulators. Launch the affected app in Simulator when a change alters runtime behavior.

## Scope

- Shared cross-platform logic belongs in `Packages/PutioCore`
- Platform UI and lifecycle behavior belongs in the matching directory under `Apps`
- Use Swift Package Manager for dependencies
- Keep generation and verification secret-free
