# Agent Guide

Native SwiftUI rewrite of the put.io apps for iOS, watchOS, and tvOS. It lives
on `next`; the App Store app is still the legacy 3.x line on protected `main`
([Distribution](docs/distribution.md)). Platform UI and lifecycle belong in
`Apps`; shared models, session, API, and feature logic belong in
`Packages/PutioCore`. Both are grouped by domain with the same folder names;
see [Development](CONTRIBUTING.md#development).

## Work in this repository

- Run `mise run bootstrap` in a fresh checkout or worktree; [mise.toml](mise.toml)
  owns the task commands and [Contributing](CONTRIBUTING.md#development) the
  generation workflow.
- Edit targets and settings in `Project.swift`, `Tuist.swift`, and
  `Tuist/Package.swift`; generated Xcode projects and workspaces are never
  committed. Tuist is local generation only; hosted cache, analytics, previews,
  and account-backed features are out of scope.
- Follow [Design Principles](DESIGN.md) for UI. Change tokens through
  [the contributor workflow](CONTRIBUTING.md#design-tokens), then regenerate;
  never hand-edit generated Swift or asset catalogs.
- For authentication changes, preserve [session recovery](docs/session.md).
  For routing changes, check [deep-link behavior](docs/deep-links.md).
- Keep checked-in defaults, generation, and verification usable without accounts,
  tokens, secrets, or downloaded brand fonts.
- Supporting docs use lowercase kebab-case under `docs/`; the uppercase root
  guides, `LICENSE`, tool-defined agent entrypoints (`AGENTS.md`, `CLAUDE.md`,
  `SKILL.md`), and upstream skill files keep their names and content.

## Hazards

- **Legacy store delivery.** The [Beta](.github/workflows/beta.yml) and
  [Release](.github/workflows/release.yml) dispatches build the shipping app
  from protected `main` with production signing and upload it to TestFlight or
  App Store Connect, where it reaches testers or users and cannot be taken
  back. The [dispatcher](.github/workflows/legacy-ios-dispatch.yml) pins the
  reviewed legacy workflow blobs: update them only after reviewing that legacy
  change, and never copy signing configuration into it.
- **Shared test account.** Live journeys and `live-fixture` use the `devs-auto`
  put.io CLI profile ([live-profile contract](docs/harness.md#live-profile-and-publishing)),
  shared with the web, Android, and TV harnesses. Each live journey approves a
  real grant and revokes it on sign-out; an interrupted approval can leave one
  live, and the harness names the manual revocation. The Account > Security
  capture lists every app on that account, so review captures before uploading
  them.
- **tvOS launch reaches put.io.** The default tvOS launch, including
  `proof --platform all`, requests an activation code; the tvOS journey covers
  sign-in offline.
- **Simulators and devices.** The harness creates, shuts down, and deletes its
  own uniquely named simulators and never opens Simulator.app; don't open it
  from automation either. If cleanup fails, delete only the run's reported
  UDIDs. Physical Apple TV builds use automatic provisioning and may register
  the device with the development team.
- **One verify per worktree.** Verify lanes share `build/DerivedData`.

## Verification and completion

`mise run verify` is the full gate; pass lanes (`checks`, `build`, `ios`,
`tvos`) to run a subset in order. Code changes pass the lanes they affect plus
the focused proof below; runtime changes also exercise the affected shell
through the [typed headless harness](docs/harness.md). Proof and journey
commands need a clean committed worktree and write under ignored `build/proof/`.
Report skipped or unavailable checks.

| Change | Focused proof |
| --- | --- |
| Docs or skill files only | None; check the links and commands you touched. Pull-request CI skips every lane for these paths |
| Shared logic | `swift test --package-path Packages/PutioCore` |
| Tooling scripts, tokens, or fonts | `pnpm run verify` |
| Manifest or dependency graph | `mise run build` (regenerates and builds every app scheme) |
| Shell logic, components, or theming | `mise run harness -- test --platform <ios\|tvos>`; intentional visual changes require inspected, re-recorded baselines |
| iOS Files browser | `mise run harness -- journey --platform ios --scenario files-browser` |
| tvOS shell or sign-in | `mise run harness -- journey --platform tvos --scenario device-sign-in` |
| Recorded platform proof | `mise run harness -- proof --platform <ios\|watchos\|tvos\|all>` |
| tvOS device launch and rendering | `mise run harness -- proof --platform tvos --device <udid>` on a [paired Apple TV](docs/harness.md#physical-apple-tv) |

## Delivery

Pull requests target `next` and squash-merge. [Next CI](.github/workflows/ci-next.yml)
runs the lanes a pull request's paths affect; a push to `next` runs every lane
and saves the Xcode compilation caches. Nothing on `next` signs, versions, or
publishes. Upload reviewed screenshots or recordings with
`gh pr comment <n> --attach ./file.png`; never commit them.

## Skills

Codex reads `.agents/skills`; Claude Code reads installer-managed links under
`.claude/skills`. When installing or restoring skills with the skills CLI, select
both `--agent codex claude-code`.

- SwiftUI state, composition, navigation, and accessibility: [SwiftUI](.agents/skills/swiftui-expert-skill/SKILL.md)
- Tasks, cancellation, actors, and Sendable: [Swift Concurrency](.agents/skills/swift-concurrency/SKILL.md)
- Test design, async tests, and migration: [Swift Testing](.agents/skills/swift-testing-expert/SKILL.md)
- Build timing and optimization: [Xcode Build Orchestrator](.agents/skills/xcode-build-orchestrator/SKILL.md), which routes to the installed benchmark, compiler, project, package, and fixer skills
- Workspace generation and target changes: [Tuist](.agents/skills/using-tuist-generated-projects/SKILL.md)
- Refreshing the skill's API reference: [SwiftUI API Updater](.agents/skills/update-swiftui-apis/SKILL.md)
