# Error handling

## Recommendation

Localize **expected** errors (network down, auth expired, API status codes the
product cares about) into actionable copy at the feature boundary. Catch
**unexpected** errors at the screen root with `ErrorState` so the whole app
shell doesn't blank out.

## Why

Same pattern as the RN tv-native app's `localizeError(error, [...])` and the
UIKit app's `InternalFailurePresenter` — keep the user staring at recoverable
copy, not a stack trace.

## Rules

- View-models surface a typed `LocalizedFailure` (title, message, retry-handler)
  rather than raw `Error`.
- `PutioSDKError` cases map through `ErrorMapping.localize(_:)` so each feature
  doesn't reinvent the copy.
- Unexpected/programmer errors throw and bubble up to the screen-level
  `ErrorState` retry surface; do not swallow.
- Never use `try?` to silence an error path that the user would otherwise
  benefit from seeing.

## Anti-patterns

- Toast everything. The remote-only TV surface has no toasts; show empty/error
  states inline with focusable retry actions.
- `do { try await ... } catch { print(error) }`. Either render the failure
  state or escalate.

## Examples

- `PutioTV/Core/API/ErrorMapping.swift`
- `PutioTV/Design/Components/ErrorState.swift`
- `PutioTV/Features/Files/FilesViewModel.swift`
