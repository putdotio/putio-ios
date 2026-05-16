# Data flow

## Recommendation

`PutioSDK` (the Swift SDK) is the only network boundary. Wrap each domain in a
thin **repository** that exposes typed Swift `async throws` methods. SwiftUI
views consume repositories through `@Observable` view-models or a `Store`
created at the dependency container.

## Why

Keeps SwiftUI views pure: they render from value-type snapshots, never call the
SDK or `URLSession` directly. Repositories also become the seam where mocks /
fixtures plug in for tests.

## Rules

- A repository talks to **one** SDK area (files, history, trash, account,
  auth). It does not know about other repositories.
- All public methods are `async throws -> Sendable`. Return SDK value DTOs or
  small repo-owned structs — never the raw open SDK class.
- Views never call `api.foo()` directly. They call a `@MainActor` view-model
  method that calls a repository.
- Repositories don't cache. Snapshotting / refresh logic lives in the
  view-model. The session container owns long-lived state (token, account).

## Anti-patterns

- A "BigStore" with every endpoint. Split by domain.
- Direct SDK calls inside SwiftUI bodies or `Task { ... }` blocks in `View`.
- Open SDK reference classes (`PutioFile`) escaping into SwiftUI state — wrap
  in a value type if it's stored long-term.

## Examples

- `PutioTV/Core/Repositories/FilesRepository.swift`
- `PutioTV/Core/Repositories/AccountRepository.swift`
- `PutioTV/Core/AppContainer.swift` for wiring.
