import SwiftUI

/// Ported 1:1 from `@putdotio/colors` `DARK_UI_COLORS` (radix `grayDark` +
/// `yellowDark` semantic spectrum). Keep this file as the only source of put.io
/// color tokens — adding ad-hoc colors at call sites breaks parity with the
/// React Native tv-native reference.
extension Color {
    enum Put {
        // MARK: gray (semantic positions 1-12 from radix grayDark)
        static let bg              = Color(hslDegrees:   0, saturation: 0,  lightness: 0.085) // gray1
        static let bgSecondary     = Color(hslDegrees:   0, saturation: 0,  lightness: 0.110) // gray2
        static let componentBg     = Color(hslDegrees:   0, saturation: 0,  lightness: 0.136) // gray3
        static let componentBgHover = Color(hslDegrees:  0, saturation: 0,  lightness: 0.158) // gray4
        static let componentBgActive = Color(hslDegrees: 0, saturation: 0,  lightness: 0.179) // gray5
        static let line            = Color(hslDegrees:   0, saturation: 0,  lightness: 0.205) // gray6
        static let border          = Color(hslDegrees:   0, saturation: 0,  lightness: 0.243) // gray7
        static let borderHover     = Color(hslDegrees:   0, saturation: 0,  lightness: 0.312) // gray8
        static let solid           = Color(hslDegrees:   0, saturation: 0,  lightness: 0.439) // gray9
        static let solidHover      = Color(hslDegrees:   0, saturation: 0,  lightness: 0.494) // gray10
        static let textSecondary   = Color(hslDegrees:   0, saturation: 0,  lightness: 0.628) // gray11
        static let text            = Color(hslDegrees:   0, saturation: 0,  lightness: 0.930) // gray12

        // MARK: yellow accents (override solid + solid-hover to put.io brand)
        static let yellowSolid      = Color(red: 0xFD / 255, green: 0xCE / 255, blue: 0x45 / 255) // #FDCE45
        static let yellowSolidHover = Color(red: 0xFC / 255, green: 0xBE / 255, blue: 0x03 / 255) // #FCBE03

        // MARK: aliases for legacy call sites (hi/lo contrast pair)
        static let hiContrast = text
        static let loContrast = bg
    }

    static var put: Put.Type { Put.self }
}

private extension Color {
    /// HSL → SwiftUI Color. Mirrors `hsl(deg, sat%, lit%)` from CSS so the
    /// radix `grayDark` values copy in by value without an off-by-channel
    /// rounding.
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
