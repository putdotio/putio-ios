import SwiftUI

/// Liquid Glass toolbar surface. Pairs the system glass material with the
/// put.io accent foreground.
struct PutGlassToolbar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: PutSpacing.sm) {
            content
        }
        .padding(.horizontal, PutSpacing.md)
        .padding(.vertical, PutSpacing.xs)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.thinMaterial)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct PutScreenHeader<Title: View, Trailing: View>: View {
    @ViewBuilder var title: Title
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PutSpacing.md) {
            title
                .font(.put.largeTitle)
                .foregroundStyle(Color.put.textPrimary)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, PutSpacing.xl)
        .padding(.top, PutSpacing.lg)
        .padding(.bottom, PutSpacing.sm)
    }
}

extension PutScreenHeader where Trailing == EmptyView {
    init(@ViewBuilder title: () -> Title) {
        self.title = title()
        self.trailing = EmptyView()
    }
}
