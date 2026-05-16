# tvOS parity checklist

Maps each phase-one exported tvOS screenshot to the SwiftUI surface that
should render it. Use this list when capturing native captures against
`../putio-frontend-handbook/docs/specs/tv-native/tvos/`.

| # | Screenshot | Native source | Status |
| --- | --- | --- | --- |
| 01 | `01-auth-code.png` | `PutioTV/Features/Auth/AuthCodeView.swift` (state `awaitingLink`) | ✅ implemented |
| 03 | `03-home.png` | `PutioTV/Features/Home/HomeView.swift` | ✅ implemented |
| 04 | `04-files-root.png` | `FilesView.swift` (parentID 0) | ✅ implemented |
| 05 | `05-files-folder.png` | `FilesView.swift` (nested) | ✅ implemented |
| 06 | `06-files-video-resume-prompt.png` | `PlayerView.swift` (state `resumePrompt`) | ✅ implemented |
| 06b | `06b-files-unsupported-type.png` | `PlayerView.swift` (state `unsupported`) | ✅ implemented |
| 07 | `07-search-empty.png` | `SearchView.swift` (state `idle`) | ✅ implemented |
| 08 | `08-history.png` | `HistoryView.swift` | ✅ implemented |
| 09 | `09-account-playback-top.png` | `AccountView.swift` (Playback section) | ✅ implemented |
| 10 | `10-account-proxy-picker.png` | `AccountView.swift` (Menu over tunnel routes) | ✅ implemented |
| 12 | `12-account-storage.png` | `AccountView.swift` (Storage section) | ✅ implemented |
| 13 | `13-trash-empty.png` | `TrashView.swift` (state `empty`) | ✅ implemented |
| 14 | `14-account-app-device.png` | `AccountView.swift` (App and device info section) | ✅ implemented |
| 15 | `15-diagnostics-list.png` | `DiagnosticsView.swift` | ✅ implemented |
| 16 | `16-diagnostics-player.png` | `DiagnosticsPlayerView.swift` (system AVPlayer) | ✅ implemented |
| 17 | `17-video-playback.png` | `PlayerView.swift` → `SystemPlayerView.swift` | ✅ implemented |
| 18 | `18-video-controls.png` | system AVPlayer chrome | ✅ system-owned |
| 19 | `19-video-subtitles-picker.png` | system AVPlayer subtitles/audio panel | ✅ system-owned |
| 20 | `20-video-controls-bright.png` | system AVPlayer chrome | ✅ system-owned |
| 21 | `21-video-info-panel.png` | system AVPlayer Info sheet | ✅ system-owned |

## Capture workflow

For each row, in the tvOS Simulator:

1. Sign in with the same test account the React Native captures used
   (`devs-fe-auto`).
2. Navigate to the screen as the user would.
3. `xcrun simctl io booted screenshot tvos/<screen-name>.png` from the
   repo root.
4. Drop the file into the same path used by the React Native baseline
   so visual diff tools can compare side-by-side.

The exported React Native captures live at:

```
../putio-frontend-handbook/docs/specs/tv-native/tvos/
```

## Known capture gaps from the plan

These were called out as missing-but-needed in the migration plan and
remain open until a developer with simulator access can produce them:

- Conversion-in-progress UI (`PlayerView` `converting` state) — needs a
  test file mid-conversion.
- tvOS populated search results — Android captures exist; tvOS does not.

Both rely on operator action (uploading a fresh file / running a
conversion) rather than code changes.
