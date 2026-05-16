import SwiftUI

/// Screen header surface. Ports `apps/tv-native/src/components/screen.tsx`:
/// content row with a 1px `line` bottom border, padded by the screen-header
/// insets (top: md + safe.top, left/right: safe, bottom: md). The trailing
/// slot mirrors the React Native Screen `actions` prop.
struct PutScreenHeader<Content: View, Trailing: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: PutSpacing.md) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.top, PutSpacing.md + PutSafe.vertical)
            .padding(.horizontal, PutSafe.horizontal)
            .padding(.bottom, PutSpacing.md)

            Rectangle()
                .fill(Color.put.line)
                .frame(height: 1)
        }
    }
}

extension PutScreenHeader where Trailing == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
        self.trailing = EmptyView()
    }
}

/// Trailing-action group used inside `PutScreenHeader { ... } trailing: { ... }`.
/// Renders children inline; styling comes from individual buttons.
struct PutHeaderActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: PutSpacing.sm) { content }
    }
}

/// put.io logo, sized to `label.fontSize` height (48pt) matching tv-native
/// `<Logo size="sm" />`.
struct PutLogo: View {
    var height: CGFloat = 48

    var body: some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("put.io")
    }
}

/// Compatibility shim. Legacy call sites wrap header actions in
/// `PutGlassToolbar { ... }`; with the new header API the trailing slot is
/// already a horizontally-stacked area, so this just forwards children.
struct PutGlassToolbar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: PutSpacing.sm) { content }
    }
}
