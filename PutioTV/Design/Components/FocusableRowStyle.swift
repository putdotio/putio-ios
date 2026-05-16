import SwiftUI

/// `ButtonStyle` for full-width list rows. Ports the tv-native list-item
/// pressable styling: transparent when blurred, `component-bg-active` when
/// focused, rounded `radii.default`, padded by `spacing.md`, with the
/// overscan-safe margins applied on the outer edges.
struct PutFocusableRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(PutSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PutRadius.default, style: .continuous)
                    .fill(isFocused ? Color.put.componentBgActive : Color.clear)
            )
            .padding(.horizontal, PutSafe.horizontal)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: isFocused)
    }
}
