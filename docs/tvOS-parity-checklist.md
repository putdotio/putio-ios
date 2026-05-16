# tvOS parity checklist

Maps each phase-one exported tvOS screenshot to the SwiftUI surface that
renders it and the matching capture under
`docs/tvOS-captures/`. All captures are simulator runs of the
`PutioTV` Xcode target (`tvOS 26.4`, Apple TV 4K 3rd gen) against the
shared frontend-ci `devs-fe-auto` test account.

Token comes from
`op://frontend-ci/putio-sdk-testing/first_party/access_token` and is
cached locally in `.env.local` (gitignored). DEBUG build of PutioTV
honors:

- `PUTIO_INJECT_TOKEN` — bypasses device-code linking, useful for parity captures.
- `PUTIO_INITIAL_TAB` — jumps the TabView shell to `files | search | history | account`.

| # | Screenshot | Native source | Capture |
| --- | --- | --- | --- |
| 01 | `01-auth-code.png` | `PutioTV/Features/Auth/AuthCodeView.swift` (`awaitingLink`) | ✅ [`01-auth-code.png`](tvOS-captures/01-auth-code.png) |
| 03 | `03-home.png` | superseded by the system TabView shell in `PutioTVApp.MainTabs` | ✅ [`03-home.png`](tvOS-captures/03-home.png) (early menu render; see TabView shots) |
| 04 | `04-files-root.png` | `FilesView` (parentID 0) | ✅ [`04-files-root.png`](tvOS-captures/04-files-root.png) |
| 05 | `05-files-folder.png` | `FilesView` (nested) | ✅ [`05-files-folder.png`](tvOS-captures/05-files-folder.png) |
| 06 | `06-files-video-resume-prompt.png` | `PlayerView` (`resumePrompt`) | ✅ [`06-files-video-resume-prompt.png`](tvOS-captures/06-files-video-resume-prompt.png) |
| 06b | `06b-files-unsupported-type.png` | `PlayerView` (`unsupported`) | ✅ [`06b-files-unsupported-type.png`](tvOS-captures/06b-files-unsupported-type.png) |
| 07 | `07-search-empty.png` | `SearchView` (`idle`) | ✅ [`07-search-empty.png`](tvOS-captures/07-search-empty.png) |
| 08 | `08-history.png` | `HistoryView` | ✅ [`08-history.png`](tvOS-captures/08-history.png) |
| 09 | `09-account-playback-top.png` | `AccountView` (Playback section) | ✅ [`09-account-playback-top.png`](tvOS-captures/09-account-playback-top.png) |
| 10 | `10-account-proxy-picker.png` | `AccountView` (Menu over tunnel routes) | ✅ [`10-account-proxy-picker.png`](tvOS-captures/10-account-proxy-picker.png) |
| 12 | `12-account-storage.png` | `AccountView` (Storage section) | ✅ [`12-account-storage.png`](tvOS-captures/12-account-storage.png) |
| 13 | `13-trash-empty.png` | `TrashView` (`empty`) | ✅ [`13-trash-empty.png`](tvOS-captures/13-trash-empty.png) |
| 14 | `14-account-app-device.png` | `AccountView` (App and device info) | ✅ [`14-account-app-device.png`](tvOS-captures/14-account-app-device.png) |
| 15 | `15-diagnostics-list.png` | `DiagnosticsView` | ✅ [`15-diagnostics-list.png`](tvOS-captures/15-diagnostics-list.png) |
| 16 | `16-diagnostics-player.png` | `DiagnosticsPlayerView` (`SystemPlayerView`) | ✅ [`16-diagnostics-player.png`](tvOS-captures/16-diagnostics-player.png) |
| 17 | `17-video-playback.png` | `PlayerView` → `SystemPlayerView` (HLS, no chrome) | ✅ [`17-video-playback.png`](tvOS-captures/17-video-playback.png) |
| 18 | `18-video-controls.png` | system AVPlayer chrome | ✅ [`18-video-controls.png`](tvOS-captures/18-video-controls.png) |
| 19 | `19-video-subtitles-picker.png` | system AVPlayer subtitles/audio panel | ⏳ system-owned; needs a longer-form file with sidecar tracks |
| 20 | `20-video-controls-bright.png` | system AVPlayer chrome on a brighter scene | ⏳ pending |
| 21 | `21-video-info-panel.png` | system AVPlayer Info sheet | ⏳ pending |

## Known gaps after the first capture pass

These are real UX issues observed against the captures and worth a
follow-up before the first TestFlight:

- **Tab strip shows over the player surface** during `playing` (visible
  in `17-video-playback.png` and `18-video-controls.png`). The
  `PlayerView` is pushed inside a per-tab `NavigationStack`, so the
  system TabView keeps drawing on top. Fix: present the player via a
  root-level `fullScreenCover` (or hide system overlays for the player
  destination).
- **Resume prompt secondary button** rendered without text on first
  capture because `.tint(Color.put.text)` collapsed white-on-white;
  partial fix landed (HStack-based label) but the prompt should be
  re-skinned to use the standalone `PutButton` for full parity.
- **Sign out** in `AccountView` uses the system `.bordered` button —
  works, but should match `PutButton`'s focused-state styling.
- **Search field** uses a SwiftUI `TextField` and auto-focuses on
  appear, trapping remote navigation. Should swap to the system
  `searchable` modifier (tvOS 26 supports it) so the system search
  keyboard / dictation handle focus correctly.
- **Account icons**: `wrench` (Diagnostics row) falls through the
  Lucide→SF Symbol map and renders as `circle`. Add wrench mapping in
  `LucideIcon.symbol(for:)`.
- **Video player AVPlayerViewController Info sheet** (screen 21) was
  not reached in this pass — needs an interactive Info-button tap which
  the simulator's keyboard remote does not surface cleanly.

## Capture workflow

```
# 1. Generate the Xcode project
cd PutioTV && xcodegen generate --spec project.yml

# 2. Build for the tvOS simulator
DEVELOPER_DIR=/Applications/Xcode-26.4.1.app/Contents/Developer \
  xcodebuild build -project PutioTV.xcodeproj -scheme PutioTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=26.4' \
  CODE_SIGNING_ALLOWED=NO

# 3. Boot + install + launch with the test token
xcrun simctl boot "Apple TV 4K (3rd generation)"
xcrun simctl install booted "<DerivedData>/Debug-appletvsimulator/PutioTV.app"
TOKEN=$(cat ../.env.local)
SIMCTL_CHILD_PUTIO_INJECT_TOKEN=$TOKEN \
SIMCTL_CHILD_PUTIO_INITIAL_TAB=files \
  xcrun simctl launch booted io.put.tvos.dev

# 4. Drive the simulator and capture
osascript -e 'tell application "System Events" to key code 125'   # Down
xcrun simctl io booted screenshot docs/tvOS-captures/04-files-root.png
```

Apple TV Remote key codes (via System Events):
`126 Up · 125 Down · 123 Left · 124 Right · 36 Select · 53 Menu`.
