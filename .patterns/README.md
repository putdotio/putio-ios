# Repo-local patterns

These files capture how this repo applies the put.io frontend pattern language
(`/putio-frontend-patterns`). The umbrella defaults live in that skill; this
folder records the iOS / tvOS specifics that win over the defaults.

| Topic | File |
| --- | --- |
| State machines (auth, playback) | [state-machines.md](state-machines.md) |
| Data flow + repositories | [data-flow.md](data-flow.md) |
| Error handling | [error-handling.md](error-handling.md) |
| Styling (UIKit iOS + SwiftUI tvOS) | [styling.md](styling.md) |
| Testing | [testing.md](testing.md) |

The iOS UIKit app under `Putio/Features` predates these notes — it documents
its conventions in `AGENTS.md`. The SwiftUI tvOS target under `PutioTV/`
adopts these patterns from day one.
