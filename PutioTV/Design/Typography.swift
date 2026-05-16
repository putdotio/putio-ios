import SwiftUI
import UIKit

/// GT America type scale, 1:1 with the React Native tv-native theme.
/// `Rg` = GT America Regular (post-script `GTAmerica-Regular`),
/// `Md` = GT America Medium. Fonts are bundled under
/// `Resources/Fonts/` and registered through `UIAppFonts` in `Info.plist`.
extension Font {
    enum Put {
        static let heading   = Font.put(.medium, size: 64) // title rows, large headers
        static let label     = Font.put(.medium, size: 48) // screen headers, "Sign in" labels
        static let body      = Font.put(.regular, size: 36) // primary list copy
        static let caption   = Font.put(.regular, size: 32) // secondary list copy
        static let smol      = Font.put(.regular, size: 24) // app-info footer
    }

    static var put: Put.Type { Put.self }
}

extension Font {
    enum PutWeight { case regular, medium, bold }

    static func put(_ weight: PutWeight, size: CGFloat) -> Font {
        let name: String = {
            switch weight {
            case .regular: return "GTAmerica-Regular"
            case .medium:  return "GTAmerica-Medium"
            case .bold:    return "GTAmerica-Bold"
            }
        }()
        if UIFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        // Fallback: short-name variants matching the Android asset filenames.
        let fallback = name
            .replacingOccurrences(of: "GTAmerica-Regular", with: "GTAmerica-Rg")
            .replacingOccurrences(of: "GTAmerica-Medium", with: "GTAmerica-Md")
            .replacingOccurrences(of: "GTAmerica-Bold", with: "GTAmerica-Bd")
        if UIFont(name: fallback, size: size) != nil {
            return .custom(fallback, size: size)
        }
        // Final fallback: system, preserves layout sizing if fonts didn't ship.
        return .system(size: size, weight: weight == .regular ? .regular : (weight == .bold ? .bold : .medium))
    }
}

/// Spacing scale ported from `tv-native` theme.
/// 0=0, xxs=4, xs=8, sm=16, md=32, lg=64, xl=128, xxl=256.
enum PutSpacing {
    static let zero: CGFloat = 0
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 16
    static let md: CGFloat = 32
    static let lg: CGFloat = 64
    static let xl: CGFloat = 128
    static let xxl: CGFloat = 256
}

/// Overscan-safe inset, ported from tv-native (~2% top/bottom, 4% left/right).
enum PutSafe {
    static let horizontal: CGFloat = 1920 * 0.04 // 76.8 ~ 77
    static let vertical: CGFloat = 1080 * 0.02   // 21.6 ~ 22
}

enum PutRadius {
    static let `default`: CGFloat = 12
}
