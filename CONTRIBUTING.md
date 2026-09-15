# Contributing

## Setup

Install Xcode 26.x or 27.x with its matching iOS, watchOS, and tvOS Simulator
runtimes, plus [mise](https://mise.jdx.dev). [Next CI](.github/workflows/ci-next.yml)
pins the CI version. The local doctor checks runtimes and compatible device
types against the selected Xcode.

```bash
mise install
mise run bootstrap
mise run open
```

[mise.toml](mise.toml) pins the tooling. Bootstrap installs dependencies,
generates the workspace, and checks the host. It needs no Tuist account,
application secret, or signing material.

For a machine-readable prerequisite report:

```bash
mise run doctor -- --output json
```

## Development

The platform shells in [Apps](Apps) own UI and lifecycle behavior;
[PutioCore](Packages/PutioCore) owns shared logic. Use Swift Package Manager for
dependencies. [Project.swift](Project.swift) owns targets, bundle identifiers,
and build settings; generated Xcode projects and workspaces are disposable.

Run `mise run generate` after manifest or dependency changes. Files added inside
existing `buildableFolders` appear without regeneration. The
[generation script](scripts/generate.sh) includes the standard-SwiftPM workaround
for Tuist's local GoogleCastSDK resolution failure. Use that command for normal
development; a standalone dependency install needs
`TUIST_USE_SWIFTERPM=0 tuist install`.

See [mise.toml](mise.toml) for the task definitions and
[AGENTS.md](AGENTS.md#skills) for repository-local Codex and Claude Code skills.

### Design tokens

Follow [Design Principles](DESIGN.md) when changing UI. Token values belong in
[putio-design](https://github.com/putdotio/putio-design); this repository consumes
the version pinned in [package.json](package.json) and [pnpm-lock.yaml](pnpm-lock.yaml).

After changing tokens upstream, bump the package here, classify new tokens in
[the coverage manifest](scripts/design-token-coverage.json), and run:

```bash
mise run tokens
```

Commit the lockfile, coverage manifest, and generated output together. Edit the
[generator](scripts/generate-design-tokens.ts) when the adapter needs to change;
do not hand-edit its Swift or asset output. Verification rejects unclassified
tokens and generated drift.

### Optional brand fonts

Missing brand fonts use system fallbacks and do not block setup or verification.
To download or repair them, then include them in the generated app resources:

```bash
mise run fonts-setup
mise run generate
```

[Config/BrandFonts.json](Config/BrandFonts.json) owns download locations, checksums,
and destination platforms. Font binaries remain ignored. `mise run verify-fonts`
checks installed files. Tests render without fonts, but native-face assertions
and brand-baseline comparisons skip; recording brand baselines requires the
fonts. CI installs them for full visual coverage.

## Verification

```bash
mise run verify
```

The [verification script](scripts/verify.sh) owns the full gate, including
[tooling and package checks](scripts/test.sh), app builds, and iOS/tvOS native
suites. Keep generation and verification secret-free.

For runtime changes, exercise the affected shell through the
[headless harness](docs/harness.md). Use the Files journey for iOS browser
changes and the device-sign-in journey for tvOS authentication. Proof and journey
commands require a clean committed worktree; commit locally before capture.
Publishing artifacts is a separate action.

For specific changes, consult [session recovery](docs/session.md),
[deep-link behavior](docs/deep-links.md), or [distribution](docs/distribution.md).
