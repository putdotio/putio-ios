# Native tvOS Target Setup

The SwiftUI tvOS app lives in `PutioTV/` and is wired through an
XcodeGen `project.yml`. The Xcode project is generated on demand; the
project file itself is not checked in.

## Tooling prerequisites

- Xcode 26.4 or newer with the tvOS 26 SDK.
- `xcodegen` (Homebrew: `brew install xcodegen`).
- `op` (1Password CLI) only if you want to drive the simulator parity
  captures against the shared `frontend-ci/putio-sdk-testing` token.

The xcode-select path on the host can point at Command Line Tools;
`DEVELOPER_DIR=/Applications/Xcode-26.4.1.app/Contents/Developer` keeps
the iOS app's existing CocoaPods workflow intact for the rest of the
repo.

## Generate + build

```
cd PutioTV
xcodegen generate --spec project.yml

DEVELOPER_DIR=/Applications/Xcode-26.4.1.app/Contents/Developer \
  xcodebuild build \
  -project PutioTV.xcodeproj \
  -scheme PutioTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=26.4' \
  CODE_SIGNING_ALLOWED=NO
```

The target depends on `PutioSDK` as a local Swift Package via
`packages.PutioSDK.path` in `project.yml`. Update that path if you
move the SDK worktree.

## Run + drive the simulator

```
xcrun simctl boot "Apple TV 4K (3rd generation)"
open -a /Applications/Xcode-26.4.1.app/Contents/Developer/Applications/Simulator.app

APP="$(xcodebuild -project PutioTV.xcodeproj -scheme PutioTV \
       -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=26.4' \
       -showBuildSettings 2>/dev/null | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR/ {print $2; exit}')/PutioTV.app"
xcrun simctl install booted "$APP"
xcrun simctl launch booted io.put.tvos.dev
```

## DEBUG helpers

The Debug build honors two `SIMCTL_CHILD_*` env vars so parity captures
can skip the device-code flow and land directly on a specific tab:

- `PUTIO_INJECT_TOKEN` — write a token straight into the keychain (and
  the UserDefaults fallback on simulator) before the auth state
  machine runs.
- `PUTIO_INITIAL_TAB` — one of `files | search | history | account`.

Token convenience (cached to `.env.local`, gitignored):

```
op read 'op://frontend-ci/putio-sdk-testing/first_party/access_token' \
  --account putdotio.1password.com > .env.local
chmod 600 .env.local

TOKEN=$(cat .env.local)
SIMCTL_CHILD_PUTIO_INJECT_TOKEN="$TOKEN" \
SIMCTL_CHILD_PUTIO_INITIAL_TAB=account \
  xcrun simctl launch --terminate-running-process booted io.put.tvos.dev
```

## Apple TV Remote key codes

```
osascript -e 'tell application "System Events" to key code N'
```

| Action | Key code |
| --- | --- |
| Up    | 126 |
| Down  | 125 |
| Left  | 123 |
| Right | 124 |
| Select | 36 |
| Menu  | 53 |

## Screenshots

```
xcrun simctl io booted screenshot path/to/file.png
```

## Adding to the existing iOS workspace

The tvOS target is currently a standalone `.xcodeproj`. Bringing it
into `Putio.xcworkspace` is a follow-up (see
[`docs/tvOS-parity-checklist.md`](tvOS-parity-checklist.md) for the
open items). The iOS app and the tvOS app share the SDK
(`putio-sdk-swift`); nothing else is shared today.
