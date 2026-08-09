# Apple Platform Harness

The repository ships a typed, headless harness for building, launching, exercising, and proving the iOS, paired watchOS, and tvOS app shells. It wraps Xcode, `simctl`, the global `putio` CLI, and `attach`; it does not replace them.

## Environment contract

A provisioned host needs Xcode 26.x, matching iOS/watchOS/tvOS Simulator runtimes, mise, and the mise-pinned Tuist version. `putio` is optional for live testing-profile checks. `attach` is optional until proof publishing.

```bash
mise install
mise run bootstrap
mise run doctor -- --output json
```

Doctor exits nonzero for missing build prerequisites and returns stable JSON with `--output json`. Optional live-lane tools produce warnings without blocking deterministic builds. Brand fonts are reported as not configured until #126 owns their contract.

## Commands

```bash
mise run harness -- help
mise run harness -- build --platform ios
mise run harness -- launch --platform watchos
mise run harness -- exercise --platform tvos
mise run harness -- screenshot --platform ios
mise run harness -- record --platform watchos --record-seconds 5
mise run harness -- proof --platform all
```

Platform values are `ios`, `watchos`, and `tvos`. `all` is supported by `build` and `proof`. Invalid platforms, options, run identifiers, durations, repositories, and pull-request numbers fail before invoking platform tools.

All simulator commands are headless. The harness never opens Simulator.app. Each run creates uniquely named devices, pairs watchOS with an ephemeral iPhone companion, waits for boot and a rendered app frame, and shuts down and deletes every created device on success or failure.

## Deterministic proof

`proof` builds, installs, records the launch, verifies the app process remains alive, waits for the display to change from its pre-launch state, and captures a screenshot. Artifacts are written beneath:

```text
build/proof/<run-id>/<platform>/
├── app.stderr.log
├── app.stdout.log
├── launch.mp4
├── manifest.json
└── signed-out.png
```

The manifest records the commit, platform, scheme, bundle identifier, runtime, device type, simulator name, fixture set, artifact sizes, and SHA-256 digests. `build/` is ignored by Git.

Capture never uploads implicitly. Publish one reviewed artifact only after a pull request exists:

```bash
mise run harness -- publish \
  --artifact build/proof/<run-id>/ios/signed-out.png \
  --repo putdotio/putio-ios \
  --pr <number>
```

## Live testing profile

Deterministic proof requires no put.io account or secret. Live smoke uses the global `putio` CLI and the dedicated `devs-fe-auto` profile:

```bash
mise run harness -- auth-status --profile devs-fe-auto --output json
mise run harness -- live-fixture --profile devs-fe-auto --output json
```

`live-fixture` is idempotent. It reuses the root `putio-ios-harness` folder or validates the write with `--dry-run` before creating it. Tokens are never read from CLI storage or written to proof artifacts. App session injection, device-code approval, and richer live fixture creation remain unavailable until their owning CLI and app contracts land.

## CI and platform limits

Pull requests into `next` run the full repository verify gate and the same headless iOS proof command. Local review evidence must cover every affected platform. Simulator proof does not claim physical-device behavior, production signing, background execution, remote-control interaction, or Apple Watch hardware behavior.
