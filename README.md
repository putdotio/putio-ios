# `@putdotio/ios`

Official iOS application of [put.io](https://itunes.apple.com/us/app/put-io/id1260479699).

## Development setup on macOS

Install iOS dependencies from [Cocoapods](https://cocoapods.org).

```zsh
bundle exec pod install
```

Fetch the development certificate.

```zsh
bundle exec fastlane match development
```

Open the workspace in Xcode and try running the app on iOS simulator.

```zsh
open Putio.xcworkspace
```

## Distribution

Install Sentry CLI for uploading debug symbols.

```zsh
brew install getsentry/tools/sentry-cli
```

Build & upload a new bundle to AppStore, which will be available for TestFlight.

```zsh
bundle exec fastlane beta
```

## Notes

- [ASAA file](https://developer.apple.com/library/content/documentation/General/Conceptual/AppSearch/UniversalLinks.html) is located [here.](../landing/static/.well-known/apple-app-site-association)
