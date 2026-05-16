import SwiftUI

/// `ButtonStyle` that gives focused list rows the put.io brand highlight on
/// top of the system focus halo. Liquid Glass material handles the rest:
/// background blur, depth, motion.
struct PutFocusableRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, PutSpacing.sm)
            .padding(.horizontal, PutSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(isFocused ? Color.put.focusRing : Color.clear, lineWidth: 3)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.18), value: isFocused)
    }
}
