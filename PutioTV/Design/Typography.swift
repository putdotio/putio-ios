import SwiftUI

/// 10-foot typography scale. tvOS rooms are bigger and reading distances are
/// longer, so we lean larger than the system defaults at the small end.
extension Font {
    enum Put {
        static let hero = Font.system(size: 88, weight: .heavy, design: .rounded)
        static let largeTitle = Font.system(size: 56, weight: .bold, design: .default)
        static let title = Font.system(size: 44, weight: .semibold, design: .default)
        static let headline = Font.system(size: 34, weight: .semibold, design: .default)
        static let body = Font.system(size: 30, weight: .regular, design: .default)
        static let secondary = Font.system(size: 26, weight: .regular, design: .default)
        static let caption = Font.system(size: 22, weight: .regular, design: .default)
        static let code = Font.system(size: 96, weight: .black, design: .monospaced)
    }

    static var put: Put.Type { Put.self }
}

enum PutSpacing {
    static let xs: CGFloat = 8
    static let sm: CGFloat = 16
    static let md: CGFloat = 24
    static let lg: CGFloat = 40
    static let xl: CGFloat = 64
    static let xxl: CGFloat = 96
}
