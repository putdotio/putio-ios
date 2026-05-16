import SwiftUI

/// put.io design tokens for the tvOS surface. Keep these in sync with the
/// `tv-native` reference theme — see
/// `apps/tv-native/src/lib/theme.ts` in `putio-web`.
extension Color {
    enum Put {
        /// Primary accent / brand. The exported tvOS screenshots show the
        /// yellow-solid swatch on the `put.io/link` callout and on focused
        /// rows.
        static let accentYellow = Color(red: 0xFE / 255, green: 0xC0 / 255, blue: 0x00 / 255)
        static let brandRed = Color(red: 0xE3 / 255, green: 0x32 / 255, blue: 0x18 / 255)

        /// Surface tints. Liquid Glass uses these only as tint hints — the
        /// system material does the visual heavy lifting.
        static let surface = Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1B / 255)
        static let surfaceElevated = Color(red: 0x1B / 255, green: 0x1E / 255, blue: 0x24 / 255)
        static let separator = Color.white.opacity(0.08)

        /// Foreground / text tokens.
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.72)
        static let textTertiary = Color.white.opacity(0.5)
        static let textNegative = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x6B / 255)

        /// Watched / progress indicator (the `eye` row badge).
        static let watched = Color.white.opacity(0.5)
        static let unwatched = Color.white.opacity(0.0)

        /// Focus highlight — used for SwiftUI focus-ring overrides where the
        /// system focus engine doesn't render one (custom buttons).
        static let focusRing = Color(red: 0xFE / 255, green: 0xC0 / 255, blue: 0x00 / 255).opacity(0.85)
    }

    static var put: Put.Type { Put.self }
}
