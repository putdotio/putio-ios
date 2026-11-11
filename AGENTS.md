# Agent Guide

Native SwiftUI rewrite of the put.io apps for iOS, watchOS, and tvOS, on the
`next` branch. Platform UI and lifecycle belong in `Apps`; shared models,
session, API, and feature logic belong in `Packages/PutioCore`.

## Work in this repository

- Run `mise run bootstrap` in a fresh checkout or worktree.
- Before SwiftUI, App Intents, test-migration, or Instruments work, run
  `mise run xcode-skills` once per worktree. It links the installed Xcode's
  agent skills into the checkout, untracked; never commit them. If the export
  hangs, skip it and say so.
- Edit targets and settings in `Project.swift`, `Tuist.swift`, and
  `Tuist/Package.swift`. Tuist is local generation only; hosted cache,
  analytics, previews, and account-backed features are out of scope.
- Follow [Design Principles](DESIGN.md) for UI. Change tokens through
  [the contributor workflow](CONTRIBUTING.md#design-tokens), then regenerate;
  never hand-edit generated Swift or asset catalogs.
- For authentication changes, preserve [session recovery](docs/session.md).
  For routing changes, check [deep-link behavior](docs/deep-links.md).
- Report crashes and errors only through the
  [telemetry boundary](docs/telemetry.md); nothing else imports Sentry.
- Reach Intercom only through `Apps/iOS/Sources/Support`
  ([support messenger](docs/support.md)).
- Keep checked-in defaults, generation, and verification usable without accounts,
  tokens, secrets, or downloaded brand fonts.

## Hazards

- **Shared test account.** Live journeys and `live-fixture` use the `devs-auto`
  put.io CLI profile ([live account][live-account]),
  shared with the web, Android, and TV harnesses. Each live journey approves a
  real grant and revokes it on sign-out; an interrupted approval can leave one
  live, and the harness names the manual revocation. The Account > Security
  capture lists every app on that account, so review captures before uploading
  them.
- **tvOS launch reaches put.io.** The default tvOS launch, including
  `proof --platform all`, requests an activation code; the tvOS journey covers
  sign-in offline.
- **Simulators and devices.** The harness creates, shuts down, and deletes its
  own uniquely named simulators headlessly; keep automation headless too, never
  through Simulator.app. If cleanup fails, delete only the run's reported
  UDIDs. Physical Apple TV builds use automatic provisioning and may register
  the device with the development team.
- **One verify per worktree.** Verify lanes share `build/DerivedData`.

## Verification and completion

`mise run verify` is the full gate; pass lanes (`tooling`, `checks`, `build`,
`ios`, `tvos`) to run a subset in order, or `--affected` for the lanes your
changes reach. Code changes pass the lanes they affect plus
the focused proof below; runtime changes also exercise the affected shell
through the [verify-putio-apple][verify] skill. Proof and journey
commands need a clean committed worktree and write under ignored `build/proof/`.
Report skipped or unavailable checks.

| Change                              | Focused proof                                                                                                          |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Docs only                           | `pnpm run markdown:check`; check web links and commands                                                                |
| Shared logic                        | `swift test --package-path Packages/PutioCore`                                                                         |
| Session lifecycle                   | `mise run formal-session`; see [verify-session-lifecycle][session-model]                                               |
| Tooling scripts, tokens, or fonts   | `pnpm run verify`                                                                                                      |
| App Store tool or asc pin           | `pnpm run verify`, then `PUTIO_REQUIRE_ASC=1 node --test scripts/app-store.test.ts` with the pinned asc on `PATH`      |
| Manifest or dependency graph        | `mise run build`                                                                                                       |
| Shell logic, components, or theming | `mise run harness -- test --platform <ios\|tvos>`; intentional visual changes require inspected, re-recorded baselines |
| iOS Files browser                   | `mise run harness -- journey --platform ios --scenario files-browser`                                                  |
| tvOS shell or sign-in               | `mise run harness -- journey --platform tvos --scenario device-sign-in`                                                |
| Recorded platform proof             | `mise run harness -- proof --platform <ios\|watchos\|tvos\|all>`                                                       |
| tvOS device launch and rendering    | `mise run harness -- proof --platform tvos --device <udid>` on a [paired Apple TV][apple-tv]                           |
| iOS redesign                        | [Redesign proof](#redesign-proof)                                                                                      |

Upload reviewed screenshots or recordings with
`gh pr comment <n> --attach ./file.png`; never commit them.

### Redesign proof

- Pass the affected lanes and the journey that exercises the behaviour.
- Capture every board the issue names on iPhone and iPad with
  `mise run harness -- journey --platform ios --boards <ids> --xxl`, plus Duo
  folded and open when it names Duo boards. The xxL capture covers each screen
  it adds or restyles.
- The pull request carries one table: board id, device, capture, differences.
  "None" is a valid difference; an empty cell is not.
- A screen that only rearranges designed content, such as an iPad or Duo
  layout, ships with a capture and names the boards it rearranges. A new layout
  waits for a board.
- Board wording is approved iOS copy. A board string with no Android key is
  `ios-only` with its reason; a string on no board stops the change.
- Changes target `next`. No TestFlight build or release is part of the proof.

[verify]: .agents/skills/verify-putio-apple/SKILL.md
[live-account]: .agents/skills/verify-putio-apple/references/live-account.md
[apple-tv]: .agents/skills/verify-putio-apple/references/apple-tv-device.md
[session-model]: .agents/skills/verify-session-lifecycle/SKILL.md
