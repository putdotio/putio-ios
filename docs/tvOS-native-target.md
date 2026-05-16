# Native tvOS Target Setup

This document captures the Xcode steps needed to wire the new SwiftUI tvOS
sources under `PutioTV/` into the existing `Putio.xcodeproj` workspace.

Status: source-complete. The current local machine has Command Line Tools
only (no full Xcode install), so the steps below need a developer machine
with Xcode 26+ and the tvOS 26 SDK to land. See "Blockers" at the end.

## 1. Add the tvOS app target

In `Putio.xcworkspace`:

1. **File → New → Target → tvOS → App**
2. Product name: `PutioTV`. Interface: **SwiftUI**. Language: **Swift**.
3. Bundle identifier suggestion: `io.put.tvos.dev` (or your signing-config
   equivalent). The `Local.xcconfig` already used by the iOS target can
   set `PRODUCT_BUNDLE_IDENTIFIER` per configuration.
4. **Don't** check "Include Tests" yet; add `PutioTVTests` later from
   File → New → Target → tvOS → Unit Testing Bundle when test wiring lands.

## 2. Add the existing source tree to the target

After Xcode creates the target's default `App.swift` + `ContentView.swift`,
**delete those two files** and instead add this repository's `PutioTV/`
folder reference to the new target:

1. Right-click `PutioTV` in the navigator → **Add Files to "Putio"…**
2. Pick the repository-root `PutioTV/` folder.
3. Choose **Create groups**, target membership: **PutioTV only**.
4. Set `PutioTV/Resources/Info.plist` as the target's Info.plist
   (Target → Build Settings → `INFOPLIST_FILE`).

## 3. Hook up PutioSDK

The tvOS target needs the `PutioSDK` Swift package or pod.

### Option A — Swift Package (recommended)

Project → Package Dependencies → `+` →
`https://github.com/putdotio/putio-sdk-swift` and pin the same commit the
iOS Podfile currently uses (`8192763563951797672c8101d6765dac3ec7e2df` at
the time of writing). Add `PutioSDK` as a framework dependency on
`PutioTV` only.

### Option B — CocoaPods alongside the iOS target

Add a `PutioTV` target block in the `Podfile`:

```ruby
target 'PutioTV' do
  platform :tvos, '26.0'
  use_frameworks!

  pod 'PutioSDK', :git => 'https://github.com/putdotio/putio-sdk-swift.git', :commit => '<same commit as iOS target>'
end
```

Then `bundle exec pod install`. The tvOS podspec helper has been updated
to expose `tvos.deployment_target = '26.0'` (see
`../putio-sdk-swift/podspec_helper.rb`).

## 4. Asset catalog + launch image

The default tvOS target creates an empty `Assets.xcassets`. Populate the
following slots before TestFlight:

- App Icon (`Brand Assets` → `App Icon - App Store` and `App Icon - Home Screen`)
- Top Shelf image (16:5)
- Launch image (or keep the storyboard-free SwiftUI launch by leaving the
  `UILaunchStoryboardName` key out of `Info.plist`)

The repo's `LaunchScreen.storyboard` is iOS-only — do not reuse it on
tvOS.

## 5. Schemes + signing

- Create a `PutioTV` scheme (Xcode auto-generates it when the target is
  added).
- Reuse the existing `Local.xcconfig` pattern for `DEVELOPMENT_TEAM`,
  `PRODUCT_BUNDLE_IDENTIFIER`, and other signing-sensitive values
  (`make secrets-setup` already provisions the iOS variant; mirror the
  same keys for tvOS).

## 6. Verify

After adding the target, run:

```
make verify          # iOS target should remain green
xcodebuild build \
  -workspace Putio.xcworkspace \
  -scheme PutioTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=26.0'
```

If your Xcode is current (Xcode 26+) the tvOS Simulator listed above will
build. Add `-only-active-arch NO` for App Store-style validation.

## Blockers from the current dev environment

The Codex worktree this was authored in had only Command Line Tools
installed:

```
$ xcodebuild -version
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer
directory '/Library/Developer/CommandLineTools' is a command line tools instance

$ xcrun --sdk appletvsimulator --show-sdk-path
xcrun: error: SDK "appletvsimulator" cannot be located
```

That blocks:

- `xcodebuild` for either iOS or tvOS targets.
- Simulator screenshots for parity comparison against
  `../putio-frontend-handbook/docs/specs/tv-native/tvos/`.
- Adding the target / asset catalog inside the `Putio.xcodeproj` file
  itself (manual `.pbxproj` editing is too risky for the iOS target).

The SDK's `swift build` (used as a smoke check for tvOS platform support)
succeeded with the macOS toolchain (`Build complete! 18.62s`).
