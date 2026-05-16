# State machines

## Recommendation

Model bug-sensitive flows as explicit Swift enums with associated values. The
states are exhaustive; the only way to move between them is a typed transition
method on the owning `@Observable` (SwiftUI) or `ObservableObject` (UIKit
presenter).

Required for: auth (device-code linking), video playback, MP4 conversion
status, transfer lifecycle, upload.

Optional but encouraged for: search input lifecycle, refresh-on-foreground.

## Why

The RN tvOS app modelled auth with a hook (`useAuthCodeAuthenticator`) that
returns a tagged-union state object — that shape ports cleanly to Swift enums.
SwiftUI `switch` over an enum gives the same exhaustiveness guarantee Match.exhaustive
gives in TypeScript. Avoid `isLoading + data + error` boolean salads.

## Rules

- One enum per flow. `Idle | Loading | Linking(...) | Linked(...) | Failed(...)`.
- Associated values carry only what the state needs (no `Optional` dumping ground).
- The owning store exposes `state: FlowState` and intent methods (`start()`,
  `restart()`, `cancel()`).
- Views render with `switch state { ... }`. Don't reach into the store to flip
  fields directly.
- Cancellation must be modelled. Use `Task` handles stored on the store and
  cancel them on transition.
- A backend error becomes a typed transition into a `.failed(LocalizedFailure)`
  state, never an `Optional` field next to a `Loading` state.

## Anti-patterns

- `@Published var isLoading: Bool` plus `@Published var error: Error?` plus
  `@Published var result: T?` — three boolean dimensions cover invalid combos.
- Long imperative methods that call `await` and update many `@Published` fields
  without going through a single transition.
- Views that branch on multiple stored booleans instead of one enum case.

## Examples

Auth state machine: see `PutioTV/Core/Auth/AuthState.swift` and
`PutioTV/Core/Auth/DeviceCodeService.swift`. Playback state machine:
`PutioTV/Core/Playback/PlaybackState.swift`.
