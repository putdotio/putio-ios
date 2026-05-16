import SwiftUI

/// Loading screen. Mirrors `apps/tv-native/src/components/loading-screen.tsx`.
struct PutLoadingState: View {
    var title: String = "Loading"

    var body: some View {
        VStack(spacing: PutSpacing.md) {
            ProgressView()
                .controlSize(.large)
                .scaleEffect(2)
                .tint(Color.put.text)
            Text(title)
                .font(.put.body)
                .foregroundStyle(Color.put.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.put.bg)
    }
}

/// Empty state. Mirrors `apps/tv-native/src/components/empty-state.tsx`:
/// centered icon (heading size), heading title, secondary message.
struct PutEmptyState: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: PutSpacing.md) {
            LucideIcon(name: icon, size: 64)
                .foregroundStyle(Color.put.textSecondary)
            Text(title)
                .font(.put.heading)
                .foregroundStyle(Color.put.text)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.put.body)
                    .foregroundStyle(Color.put.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, PutSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Error state. Mirrors `apps/tv-native/src/components/error-state.tsx`.
struct PutErrorState: View {
    let failure: LocalizedFailure
    var retryLabel: String = "Try again"

    var body: some View {
        VStack(spacing: PutSpacing.md) {
            LucideIcon(name: "circle-x", size: 64)
                .foregroundStyle(Color.put.text)
            Text(failure.message)
                .font(.put.heading)
                .foregroundStyle(Color.put.text)
                .multilineTextAlignment(.center)
            if let recovery = failure.recovery {
                Text(recovery)
                    .font(.put.body)
                    .foregroundStyle(Color.put.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, PutSpacing.xxl)
            }
            if let retry = failure.retry {
                PutButton(title: retryLabel, icon: "refresh-ccw", action: retry)
                    .padding(.top, PutSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Standalone button matching `apps/tv-native/src/components/ui/button.tsx`:
/// uppercase label, white text, optional icon, focused = component-bg-active,
/// blurred = component-bg, border = border / border-hover.
struct PutButton: View {
    let title: String
    var icon: String? = nil
    var hasTVPreferredFocus: Bool = false
    let action: () -> Void

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Button(action: action) {
            HStack(spacing: PutSpacing.sm) {
                if let icon {
                    LucideIcon(name: icon, size: 36)
                        .foregroundStyle(Color.put.text)
                }
                Text(title.uppercased())
                    .font(.put.caption)
                    .foregroundStyle(Color.put.text)
            }
            .padding(.horizontal, PutSpacing.md)
            .padding(.vertical, PutSpacing.sm)
        }
        .buttonStyle(PutSecondaryButtonStyle())
    }
}

struct PutSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: PutRadius.default, style: .continuous)
                    .fill(isFocused ? Color.put.componentBgActive : Color.put.componentBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PutRadius.default, style: .continuous)
                    .strokeBorder(isFocused ? Color.put.borderHover : Color.put.border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.12), value: isFocused)
    }
}
