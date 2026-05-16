# tvOS parity checklist

Maps each phase-one exported tvOS screenshot to the SwiftUI surface that
renders it and to the matching capture under `docs/tvOS-captures/`.

The simulator captures are produced against the shared frontend-ci
`devs-fe-auto` test account on the Apple TV 4K (3rd gen) tvOS 26.4
simulator. The token is cached locally in `.env.local` (gitignored).

DEBUG launch helpers honored by the app:

- `SIMCTL_CHILD_PUTIO_INJECT_TOKEN=…` — bypass the device-code flow.
- `SIMCTL_CHILD_PUTIO_INITIAL_TAB=files|search|history|account` — jump
  the TabView shell to a specific tab on launch.

Shell setup (Xcode 26.4 + tvOS 26.4 SDK + `xcodegen`):

```
export DEVELOPER_DIR=/Applications/Xcode-26.4.1.app/Contents/Developer
cd PutioTV && xcodegen generate --spec project.yml
xcodebuild build -project PutioTV.xcodeproj -scheme PutioTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=26.4' \
  CODE_SIGNING_ALLOWED=NO
```

## Screen status

| # | Reference screen | SwiftUI source | Native capture |
| --- | --- | --- | --- |
| 01 | `01-auth-code.png` | `PutioTV/Features/Auth/AuthCodeView.swift` | ✅ [`01-auth-code.png`](tvOS-captures/01-auth-code.png) |
| 03 | `03-home.png` | superseded by the system top `TabView` shell in `PutioTV/App/PutioTVApp.swift` | n/a |
| 04 | `04-files-root.png` | `Features/Files/FilesView.swift` (parentID 0) | ✅ [`04-files-root.png`](tvOS-captures/04-files-root.png) |
| 05 | `05-files-folder.png` | `FilesView` (nested) | ✅ [`05-files-folder.png`](tvOS-captures/05-files-folder.png) |
| 06 | `06-files-video-resume-prompt.png` | `Features/Player/PlayerView.swift` (`resumePrompt`) | ✅ [`06-files-video-resume-prompt.png`](tvOS-captures/06-files-video-resume-prompt.png) |
| 06b | `06b-files-unsupported-type.png` | `PlayerView` (`unsupported`) via `ContentUnavailableView` | ✅ [`06b-files-unsupported-type.png`](tvOS-captures/06b-files-unsupported-type.png) |
| 07 | `07-search-empty.png` | `Features/Search/SearchView.swift` + `.searchable` | ✅ [`07-search-empty.png`](tvOS-captures/07-search-empty.png) |
| 08 | `08-history.png` | `Features/History/HistoryView.swift` | ✅ [`08-history.png`](tvOS-captures/08-history.png) |
| 09 | `09-account-playback-top.png` | `Features/Account/AccountView.swift` (Form, Playback section) | ✅ [`09-account-playback-top.png`](tvOS-captures/09-account-playback-top.png) |
| 10 | `10-account-proxy-picker.png` | `Features/Account/AccountView.swift` → `TunnelPickerView` push | ✅ [`10-account-proxy-picker.png`](tvOS-captures/10-account-proxy-picker.png) |
| 12 | `12-account-storage.png` | `AccountView` (Storage section) | ✅ [`12-account-storage.png`](tvOS-captures/12-account-storage.png) |
| 13 | `13-trash-empty.png` | `Features/Trash/TrashView.swift` | ✅ [`13-trash-empty.png`](tvOS-captures/13-trash-empty.png) |
| 14 | `14-account-app-device.png` | `AccountView` (App section) | ✅ [`14-account-app-device.png`](tvOS-captures/14-account-app-device.png) |
| 15 | `15-diagnostics-list.png` | `Features/Diagnostics/DiagnosticsView.swift` | ✅ [`15-diagnostics-list.png`](tvOS-captures/15-diagnostics-list.png) |
| 16 | `16-diagnostics-player.png` | `DiagnosticsPlayerView` via `SystemPlayerView` | ✅ [`16-diagnostics-player.png`](tvOS-captures/16-diagnostics-player.png) |
| 17 | `17-video-playback.png` | `PlayerView` → `SystemPlayerView` (HLS) | ✅ [`17-video-playback.png`](tvOS-captures/17-video-playback.png) |
| 18 | `18-video-controls.png` | system AVPlayer chrome | ✅ [`18-video-controls.png`](tvOS-captures/18-video-controls.png) |
| 19 | `19-video-subtitles-picker.png` | system AVPlayer subtitles/audio panel | ⏳ system-owned; needs a file with sidecar tracks |
| 20 | `20-video-controls-bright.png` | system AVPlayer chrome on a brighter scene | ⏳ pending |
| 21 | `21-video-info-panel.png` | system AVPlayer Info sheet | ⏳ pending |

## Architecture notes

- Tab shell: `MainTabs` (`PutioTV/App/PutioTVApp.swift`) renders the
  system top `TabView` with four tags (`files | search | history |
  account`). History is conditionally hidden when
  `account_settings.history_enabled` is false.
- Player presentation: `PlayerView` is presented via
  `.fullScreenCover(item:)` driven by `PlayerPresenter` on
  `AppContainer`, so the system tab strip stops drawing over video.
- Auth state machine: `AuthSession` + `AuthState` in
  `PutioTV/Core/Auth/`. Token lives in the keychain, with a
  UserDefaults fallback when the simulator entitlement check fails.
- Playback state machine: `PlaybackSession` + `PlaybackState` in
  `PutioTV/Core/Playback/`. HLS source resolution is centralized in
  `PlaybackSourceResolver` (tvOS forces HLS).
- Subtitle preference: `SystemPlayerView.SubtitlePreference` honors
  `account_settings.dont_autoselect_subtitles` and
  `account_settings.hide_subtitles` at playback time.

## Open follow-ups

Tracked in this checklist for the next iteration:

- AVPlayer Info-sheet capture (screen 21) — needs an Info-button press
  the simulator's keyboard remote does not surface cleanly.
- Conversion-in-progress capture — needs an actual mid-conversion file
  on the test account.
- Search: recent-queries + Search Settings entry to match the React
  Native `SearchHeader` chips and modal.
- `PutioFile` snapshot value type — repos still return SDK open
  classes; eventually move to a `FileSnapshot` to satisfy Swift 6
  Sendable.
