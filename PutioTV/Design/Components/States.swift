import SwiftUI

struct PutLoadingState: View {
    var title: String = "Loading…"

    var body: some View {
        VStack(spacing: PutSpacing.md) {
            ProgressView()
                .controlSize(.large)
                .scaleEffect(2)
            Text(title)
                .font(.put.headline)
                .foregroundStyle(Color.put.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PutEmptyState: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: PutSpacing.md) {
            LucideIcon(name: icon, size: 96)
                .foregroundStyle(Color.put.textTertiary)
            Text(title)
                .font(.put.title)
                .foregroundStyle(Color.put.textPrimary)
            if let message {
                Text(message)
                    .font(.put.secondary)
                    .foregroundStyle(Color.put.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(PutSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PutErrorState: View {
    let failure: LocalizedFailure
    var retryLabel: String = "Try again"

    var body: some View {
        VStack(spacing: PutSpacing.md) {
            LucideIcon(name: "circle-x", size: 88)
                .foregroundStyle(Color.put.textNegative)
            Text(failure.message)
                .font(.put.title)
                .foregroundStyle(Color.put.textPrimary)
                .multilineTextAlignment(.center)
            if let recovery = failure.recovery {
                Text(recovery)
                    .font(.put.secondary)
                    .foregroundStyle(Color.put.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, PutSpacing.xl)
            }
            if let retry = failure.retry {
                Button(action: retry) {
                    Label(retryLabel, systemImage: "arrow.clockwise")
                        .font(.put.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.put.accentYellow)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
