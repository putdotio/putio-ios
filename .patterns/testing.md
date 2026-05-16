# Testing

## Recommendation

- **UIKit iOS app**: `PutioTests/` uses XCTest, mocks `PutioSDK` via the E2E
  mock URL protocol when end-to-end flows are involved.
- **SwiftUI tvOS target**: testable seams live on the **repository**
  protocols and `AuthSession` / `PlaybackSession` types. Use protocol-typed
  initialisers and inject fakes; do not mock `URLSession` for state-machine
  tests.

## Why

The state-machine pattern doesn't need network mocks to be tested — it just
needs control over the inputs (next polling result, next start-from value).

## Rules

- Each `Service`/`Repository` defines a protocol. View-models depend on the
  protocol; production code injects the real implementation; tests inject a
  fake.
- Time-sensitive logic (polling, throttling progress write-back) takes a
  `Clock` (`Clock.suspending` in production, `TestClock` in tests).
- Snapshot tests are not required for parity; native tvOS captures live next
  to the React Native exported baseline.

## Anti-patterns

- Testing through SwiftUI rendering with `ViewInspector` for state-machine
  behaviour. Test the state machine directly.
- Reading from the live `PutioSDK` singleton in tests.

## Examples

- Auth: covered indirectly through `PutioTests/ErrorPresentationTests.swift`
  (UIKit) and added separately for the tvOS target in `PutioTVTests/` when
  the test target is wired up.
