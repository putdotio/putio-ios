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

Bootstrap also downloads the licensed brand fonts from `static.put.io` into the ignored
`Resources/BrandFonts` directory. `Config/BrandFonts.json` pins every URL, checksum, and destination
platform. Run `mise run fonts-setup` to repair the local set or `mise run verify-fonts` for a read-only
check. Verification intentionally fails when fonts are absent, partial, changed, or unlisted.
`mise run fonts-setup` repairs all four states; because the directory is a generated build input, it
removes unlisted OTF or TTF files before restoring the manifest set.

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

The committed `PutioTheme+Generated.swift` adapter and `PutioColors.xcassets` catalog come from the exact `@putdotio/design` version in `pnpm-lock.yaml`.

```bash
mise run tokens
```

Do not edit generated Swift, generated asset catalogs, or token values directly. Update tokens in `putio-design`, bump the package version here, classify every new token in `scripts/design-token-coverage.json`, regenerate, and commit the lockfile, coverage audit, and generated output together. The verification lane fails on an unclassified token or generated-output drift.

Use fixed spacing tokens for structural layout. Add a semantic `PutioMetricRole` when spacing or meaningful icon geometry should scale with Dynamic Type; select the text style explicitly rather than scaling the whole spacing ramp.

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
