# Test fixtures

## `putio-2.58.0.realm`

The `Documents/default.realm` that App Store 2.58.0 (211) leaves behind: Realm
3.19.1, file format 9, schema version 11. Realm 20 copies it to
`default.v9.backup.realm`, then rejects it with error 16, so `PutioRealm.setup()`
deletes both and flags download recovery. `PutioRealmTests` pins that path
against this file.

2.58.0's own model classes wrote it, with synthetic values only:

| Class | Rows |
| --- | --- |
| `User`, `UserDisk`, `UserSettings` | id 4242, `fixture@example.invalid`, download token `fixture-download-token`, sort `NAME_ASC` |
| `UserConfig` | `chromecastPlaybackType` `mp4` |
| `Download` | 501 completed audio, 502 completed video, 503 queued video |

### Regenerate

1. From a checkout of this repository, add a throwaway worktree of the tree 211
   shipped from, and never commit from it:

   ```sh
   git worktree add --detach build/wt/v2580 b4d6ff2
   ```

2. Apply the build-only patches there:
   - In the `Podfile`, point SwiftGifOrigin at the mirror (the original repo is
     gone): `pod 'SwiftGifOrigin', :git => 'https://github.com/Expensify/SwiftGif.git', :tag => 'v1.6.1'`.
   - Run `pod install` with this repository's bundle:
     `BUNDLE_GEMFILE=<this checkout>/Gemfile bundle exec pod install`.
   - Add `#include <exception>` at the top of
     `Pods/Sentry/Sources/SentryCrash/Recording/Monitors/SentryCrashMonitor_CPPException.cpp`.
3. In `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, right after
   `configureSDKs()`, write the rows above through `try! Realm()` when a launch
   environment variable is set: plain `User()`, `UserDisk()`, `UserSettings()`,
   `UserConfig()` and `Download()` objects. Downloads use `size` 1048576,
   `createdAt` 2024-02-23, and `startFrom` 42 (501) and 60 (502).
4. Build for x86_64, since Realm 3.19.1's prebuilt core has no arm64-simulator
   slice, and run it under Rosetta on an iOS 26.x simulator. iOS 27's runtime is
   arm64-only.

   ```sh
   xcodebuild build -workspace Putio.xcworkspace -scheme Putio -configuration Debug \
     -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
     ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO IPHONEOS_DEPLOYMENT_TARGET=15.0 \
     CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- PROVISIONING_PROFILE_SPECIFIER= DEVELOPMENT_TEAM=
   ```

5. Install it on a simulator you created, launch it with the variable set
   (`SIMCTL_CHILD_<name>=1 xcrun simctl launch <udid> com.putio.tvOS`), terminate
   it, and copy
   `$(xcrun simctl get_app_container <udid> com.putio.tvOS data)/Documents/default.realm`
   here.
6. Check the header: `xxd -s 16 -l 6 putio-2.58.0.realm` prints `T-DB` and
   `0909`, format 9.
