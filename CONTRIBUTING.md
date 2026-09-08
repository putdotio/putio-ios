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

`mise install` provides the pinned Tuist, Node.js, and pnpm releases. Bootstrap installs the locked Node dependencies, provisions the brand fonts, generates `Putio.xcworkspace`, and runs the harness doctor. It requires no Tuist login or private configuration.

`Config/BrandFonts.json` pins the URL, checksum, and destination platforms of every licensed font
downloaded from `static.put.io` into the ignored `Resources/BrandFonts` directory. Font binaries are
never committed. `mise run verify-fonts` fails when fonts are absent, partial, changed, or unlisted;
`mise run fonts-setup` repairs all four states and removes unlisted OTF or TTF files from that
directory before restoring the manifest set.

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

This installs the locked Node tooling, regenerates the workspace, runs the harness doctor, runs the tooling tests with token and font drift checks, lints with `swift format`, runs the `PutioCore` and harness package tests plus the simulator interruption check, builds the iOS, watchOS, and tvOS schemes against generic simulators, and asserts the iOS and tvOS snapshot suites.

Use the headless harness for runtime-sensitive changes:

```bash
mise run harness -- exercise --platform ios
mise run harness -- proof --platform ios
mise run harness -- journey --platform ios --scenario files-browser
```

Run the browser journey for iOS file-browser changes. The harness never opens Simulator.app and deletes the isolated devices it creates. See [Apple Platform Harness](./docs/HARNESS.md) for structured output, watchOS pairing, proof manifests, live `devs-auto` profile checks, and separate artifact publishing.

## Scope

- Shared cross-platform logic belongs in `Packages/PutioCore`
- Platform UI and lifecycle behavior belongs in the matching directory under `Apps`
- Use Swift Package Manager for dependencies
- Keep generation and verification secret-free
