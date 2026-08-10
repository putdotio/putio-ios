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

Bootstrap validates Xcode, installs the pinned Tuist, Node.js, and pnpm releases through mise, resolves package dependencies, and generates `Putio.xcworkspace`. It requires no Tuist login or private configuration.

For a machine-readable environment report:

```bash
mise run doctor -- --output json
```

## Development

Edit `Project.swift` when changing the Xcode graph. Generated Xcode projects and workspaces are disposable and ignored by Git.

```bash
mise run generate
mise run open
```

Source changes inside existing `buildableFolders` appear without regenerating. Regenerate after manifest or dependency-graph changes.

### Design tokens

The committed `PutioTheme+Generated.swift` adapter comes from the exact `@putdotio/design` version in `pnpm-lock.yaml`.

```bash
mise run tokens
```

Do not edit the generated Swift or token values directly. Update tokens in `putio-design`, bump the package version here, regenerate, and commit the lockfile and generated output together. The verification lane fails when they drift.

## Verification

```bash
mise run verify
```

This installs the locked token tooling, checks generated-output drift, runs the `PutioCore` and harness tests, then builds the iOS, watchOS, and tvOS schemes against generic simulators. Exercise the affected shell with the headless harness when a change alters runtime behavior.

Use the headless harness for runtime-sensitive changes:

```bash
mise run harness -- exercise --platform ios
mise run harness -- proof --platform ios
```

The harness never opens Simulator.app and deletes the isolated devices it creates. See [Apple Platform Harness](./docs/HARNESS.md) for structured output, watchOS pairing, proof manifests, live testing-profile readiness, and separate artifact publishing.

## Scope

- Shared cross-platform logic belongs in `Packages/PutioCore`
- Platform UI and lifecycle behavior belongs in the matching directory under `Apps`
- Use Swift Package Manager for dependencies
- Keep generation and verification secret-free
