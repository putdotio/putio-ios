# PutioTV target

Native SwiftUI tvOS app for put.io. Replaces the React Native `tv-native`
reference surface (in `../putio-web/apps/tv-native`).

## Architecture

```
PutioTV/
├── App/                # SwiftUI App entry, DI container, root router
├── Core/               # Shared Apple core (auth, repositories, playback)
│   ├── Auth/           # Token store + device-code state machine
│   ├── API/            # PutioSDK factory + error mapping
│   ├── Repositories/   # Files, Account, History, Trash, Media
│   └── Playback/       # Source resolver + playback state machine
├── Design/             # Color, typography, components
│   └── Components/     # Lucide icon wrapper, list row, focus styles, glass
├── Features/           # One folder per surface, mirrors `tv-native`
│   ├── Auth/           # 01-auth-code
│   ├── Home/           # 03-home
│   ├── Files/          # 04, 05, 06, 06b
│   ├── Search/         # 07
│   ├── History/        # 08
│   ├── Account/        # 09, 10, 12, 14
│   ├── Trash/          # 13
│   ├── Diagnostics/    # 15, 16
│   └── Player/         # 17–21
└── Resources/          # Info.plist
```

## Patterns

Repo-local pattern docs live at the project root in `.patterns/`. The
SwiftUI tvOS target adopts them from day one (state machines, repository
data flow, localized errors, design tokens).

## Xcode wiring

The Swift sources live in this folder so they can be added to a new
target in Xcode in a single step. See
[`docs/tvOS-native-target.md`](../docs/tvOS-native-target.md) for the
project / scheme / signing setup.

## Parity oracle

The exported tvOS screenshot set at
`../putio-frontend-handbook/docs/specs/tv-native/tvos/` is the visual
parity baseline. Behavior is anchored to the React Native source at
`../putio-web/apps/tv-native/src/`.
