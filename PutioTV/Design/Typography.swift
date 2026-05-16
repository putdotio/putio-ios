import SwiftUI

/// Compact spacing scale. The native primitives we lean on (List, Form,
/// Section, ContentUnavailableView) own their own padding; we only need a
/// couple of values for the file-row layouts.
enum PutSpacing {
    static let xs: CGFloat = 8
    static let md: CGFloat = 32
}
