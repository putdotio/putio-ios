import SwiftUI

/// put.io accent + bg tokens. The native primitives we lean on (List, Form,
/// ContentUnavailableView, Toggle, Picker, Button styles) inherit color
/// from the asset-catalog AccentColor and the system semantic palette, so
/// we only keep the two brand tokens here:
///
/// - `Color.put.bg` — the dark surface used on the auth screen behind the
///   activation tiles. Other screens defer to the system default.
/// - `Color.put.yellowSolid` — explicit brand yellow for the put.io
///   wordmark callout, the resume-prompt action, and the ProgressView in
///   the Account header.
extension Color {
    enum Put {
        static let bg = Color(hslDegrees: 0, saturation: 0, lightness: 0.085) // radix grayDark.gray1
        static let yellowSolid = Color(red: 0xFD / 255, green: 0xCE / 255, blue: 0x45 / 255) // #FDCE45
    }

    static var put: Put.Type { Put.self }
}

private extension Color {
    /// HSL → SwiftUI Color. Lets the radix `grayDark.gray1` lightness copy
    /// in by value, no channel-rounding skew.
    init(hslDegrees h: Double, saturation s: Double, lightness l: Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs(fmod(h / 60, 2) - 1))
        let m = l - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch h {
        case ..<60:    (r1, g1, b1) = (c, x, 0)
        case ..<120:   (r1, g1, b1) = (x, c, 0)
        case ..<180:   (r1, g1, b1) = (0, c, x)
        case ..<240:   (r1, g1, b1) = (0, x, c)
        case ..<300:   (r1, g1, b1) = (x, 0, c)
        default:       (r1, g1, b1) = (c, 0, x)
        }
        self.init(red: r1 + m, green: g1 + m, blue: b1 + m)
    }
}
