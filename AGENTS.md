# Agent Guide

Native SwiftUI apps for iOS, watchOS, and tvOS. Platform UI and lifecycle belong
in `Apps`; shared models, session, API, and feature logic belong in
`Packages/PutioCore`.

## Work in this repository

Use lowercase kebab-case for authored documentation. Keep tool-defined agent
entrypoints (`AGENTS.md`, `CLAUDE.md`, `SKILL.md`) and upstream skill files intact.

- Follow [Contributing](contributing.md) for setup. Run `mise run bootstrap` in a
  fresh checkout or worktree; [mise.toml](mise.toml) owns the task commands.
- Edit targets and settings in `Project.swift`, `Tuist.swift`, and
  `Tuist/Package.swift`. Generated Xcode projects and workspaces are never committed.
- Use Swift Package Manager for dependencies. Tuist is local project generation
  tooling; hosted cache, analytics, previews, and account-backed features are out of scope.
- Follow [Design Principles](design.md) for UI. Change tokens through
  [the contributor workflow](contributing.md#design-tokens), then regenerate;
  never hand-edit generated Swift or asset catalogs.
- For authentication changes, preserve [session recovery](docs/session.md).
  For routing changes, check [deep-link behavior](docs/deep-links.md).
- Keep checked-in defaults, generation, and verification usable without accounts,
  tokens, secrets, or downloaded brand fonts.

## Verification and completion

Run `mise run verify` before handoff and fix change-caused failures. Completion
requires that gate plus the affected shell running in its simulator or passing
harness proof. Report skipped or unavailable checks explicitly.

Use the [typed headless harness](docs/harness.md); never open Simulator.app from
automation. Its devices are ephemeral and deleted after each command. Keep
capture local; publish only after reviewing the artifact and receiving authorization.

| Change | Required focused proof |
| --- | --- |
| Shared logic | `swift test --package-path Packages/PutioCore` |
| Manifest or dependency graph | Regenerate and build every app scheme |
| Runtime behavior | Launch or exercise the affected shell in addition to verification |
| Components or theming | `mise run harness -- test --platform <ios\|tvos>`; intentional visual changes require inspected, re-recorded baselines |
| iOS Files browser | `mise run harness -- journey --platform ios --scenario files-browser` |
| tvOS shell or sign-in | `mise run harness -- journey --platform tvos --scenario device-sign-in` |
| Recorded platform proof | `mise run harness -- proof --platform <ios\|watchos\|tvos\|all>` |

Deterministic checks are secret-free. Live smoke uses only the `devs-auto`
put.io CLI profile described in the harness contract. Proof artifacts and
manifests live under ignored `build/proof/`.

Finish authorized edits, checks, and fixes without pausing. Ask before publishing,
TestFlight or store actions, signing changes, or work outside the task. Follow
[Distribution](docs/distribution.md) for release ownership and
[Security](security.md) for private reports.

## Skills

Codex reads `.agents/skills`; Claude Code reads installer-managed links under
`.claude/skills`. `CLAUDE.md` links to this guide. When installing or restoring
skills with the skills CLI, select both `--agent codex claude-code`.

- SwiftUI state, composition, navigation, and accessibility: [SwiftUI](.agents/skills/swiftui-expert-skill/SKILL.md)
- Tasks, cancellation, actors, and Sendable: [Swift Concurrency](.agents/skills/swift-concurrency/SKILL.md)
- Test design, async tests, and migration: [Swift Testing](.agents/skills/swift-testing-expert/SKILL.md)
- Build timing and optimization: [Xcode Build Orchestrator](.agents/skills/xcode-build-orchestrator/SKILL.md), which routes to the installed benchmark, compiler, project, package, and fixer skills
- Workspace generation and target changes: [Tuist](.agents/skills/using-tuist-generated-projects/SKILL.md)
- Refreshing the skill's API reference: [SwiftUI API Updater](.agents/skills/update-swiftui-apis/SKILL.md)
