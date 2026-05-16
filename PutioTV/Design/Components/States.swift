import SwiftUI

/// Branded loading screen for the auth flow. Other screens use inline
/// `ProgressView()`; this one paints a black background so it reads against
/// `Color.put.bg.ignoresSafeArea()` on the welcome surface.
struct PutLoadingState: View {
    var title: String = "Loading"

    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

/// Native error surface built on `ContentUnavailableView`. Used inside list
/// content (loaded-state failures) and on the player when something fails.
struct FailureView: View {
    let failure: LocalizedFailure

    var body: some View {
        ContentUnavailableView {
            Label(failure.message, systemImage: "exclamationmark.triangle")
        } description: {
            if let recovery = failure.recovery {
                Text(recovery)
            }
        } actions: {
            if let retry = failure.retry {
                Button {
                    retry()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

/// Back-compat alias so existing call sites compile while feature files migrate.
typealias PutErrorState = FailureView
