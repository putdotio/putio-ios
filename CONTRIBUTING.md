# Contributing

## Setup

Install the Xcode named in [.xcode-version](.xcode-version) with its matching
iOS, watchOS, and tvOS Simulator runtimes and the iPhone Duo runtime, plus
[mise](https://mise.jdx.dev). CI and the local doctor both read that file; the
doctor also checks runtimes and device types against the selected Xcode.

```bash
mise install
mise run bootstrap
mise run open
```

[mise.toml](mise.toml) pins the tooling and defines the tasks. Bootstrap installs
dependencies, generates the workspace, and checks the host. It needs no Tuist
account, application secret, or signing material.

App Store work also needs the pinned [asc](https://asccli.sh) CLI, which
`mise install` does not provide. Install it and turn its telemetry off once:

```bash
./scripts/install-asc.sh   # asc 5.15.0 into ~/.local/bin, checksum-verified
asc telemetry disable
```

For a machine-readable prerequisite report:

```bash
mise run doctor -- --output json
```

## Development

The platform shells in [Apps](Apps) own UI and lifecycle behavior;
[PutioCore](Packages/PutioCore) owns shared logic. Use Swift Package Manager for
dependencies. [Project.swift](Project.swift) owns targets, bundle identifiers,
and build settings; generated Xcode projects and workspaces are disposable.

Sources are grouped by domain, and the iOS and tvOS shells reuse PutioCore's
folder names: `Files`, `Playback`, `Account`, `History`, `Trash`, `Session`. A
shell adds a folder only for a domain the core lacks, such as iOS `Cast` and
`Offline`. `App/` holds entry points, root and tab views, deep links, and
wiring; `Components/` holds cross-domain UI; `Harness/` holds harness-only code.
PutioCore also keeps `Runtime/` for the API client, plus `Generated/` and
`Resources/`. PutioCore and iOS unit tests mirror their sources' folders; the
tvOS, UI, and snapshot test targets stay flat.

Run `mise run generate` after manifest or dependency changes. Files added inside
existing `buildableFolders` appear without regeneration. The
[generation script](scripts/generate.sh) includes the standard-SwiftPM workaround
for Tuist's local GoogleCastSDK resolution failure. Use that command for normal
development; a standalone dependency install needs
`TUIST_USE_SWIFTERPM=0 tuist install`.

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

### Copy

User-facing strings live in String Catalogs, keyed by their English text: the
[iOS catalog](Apps/iOS/Sources/Localizable.xcstrings) and the
[PutioCore catalog](Packages/PutioCore/Sources/PutioCore/Resources/Localizable.xcstrings),
which code looks up with `bundle: .module`. Each key's comment records its
Android string as `android: <key>`, `android: <key> | differs: <reason>`, or
`ios-only: <reason>`. The `checks` lane runs
[the catalog check](scripts/string-catalog.ts) against the
[Android snapshot](Config/AndroidStrings.json); refresh the snapshot from a
putio-android checkout:

```bash
pnpm strings:android ~/projects/putdotio/putio-android
```

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
fonts. CI installs them and sets `PUTIO_REQUIRE_BRAND_FONTS=1`, so a missing face
fails there instead of skipping.

## Verification

```bash
mise run verify
```

The [verification script](scripts/verify.sh) owns the full gate and its lanes;
pass lanes to run a subset in order, as in `mise run verify checks tvos`. Tasks
live in [mise-tasks.toml](mise-tasks.toml). Keep generation and verification
secret-free.

The `tooling` lane includes the oxfmt Markdown check; `pnpm exec oxfmt "**/*.md"`
fixes findings. [.oxfmtrc.json](.oxfmtrc.json) skips each upstream skill in
[skills-lock.json](skills-lock.json), which keeps its upstream content; add a
newly installed one there. Repository-owned skills, such as `verify-putio-apple`,
are checked.

`mise run dead-code` builds both app shells with their tests, PutioCore, and the
harness, then runs [Periphery](.periphery.yml) over them; it is local only.

For runtime changes, exercise the affected shell through the
[headless harness](.agents/skills/verify-putio-apple/SKILL.md); the
[proof table](AGENTS.md#verification-and-completion) maps change types to the
required journey or snapshot command. Proof and journey commands require a clean
committed worktree. Publishing artifacts is a separate action; the pull request
template names the upload route, and media never goes in the branch.

For specific changes, consult [session recovery](docs/session.md),
[deep-link behavior](docs/deep-links.md), or [distribution](docs/distribution.md).
