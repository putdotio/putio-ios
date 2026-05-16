import SwiftUI

/// Loading-state placeholder for the player full-screen surface. Other screens
/// use `ProgressView()` inline; this one keeps a black background so it reads
/// against `Color.black.ignoresSafeArea()` in the player cover.
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
                .buttonStyle(.bordered)
            }
        }
    }
}

/// Back-compat alias so existing call sites compile while feature files migrate.
typealias PutErrorState = FailureView

/// Auth-only branded button. The auth screen is a pre-sign-in surface so the
/// custom yellow look stays — feature views use system buttons.
struct PutButton: View {
    let title: String
    var icon: String? = nil
    var hasTVPreferredFocus: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: LucideIcon.symbol(for: icon))
                }
                Text(title)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.put.yellowSolid)
    }
}
