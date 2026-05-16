import SwiftUI

/// Lucide-shaped icon wrapper for the tvOS surface. The first phase ships
/// against SF Symbols with a Lucide → SF Symbol name map so the rest of the
/// app can stay icon-agnostic; the icon source can later swap to a SwiftUI
/// Lucide package or checked-in SVG subset without touching call sites.
///
/// The keys (left side) match the icon strings used by the RN tv-native
/// reference (`apps/tv-native/src/components/list-item.tsx` etc.).
struct LucideIcon: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: Self.symbol(for: name))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static func symbol(for name: String) -> String {
        switch name {
        case "folder-closed", "folder": return "folder.fill"
        case "search": return "magnifyingglass"
        case "history": return "clock"
        case "user": return "person.crop.circle"
        case "log-out": return "rectangle.portrait.and.arrow.right"
        case "refresh-ccw": return "arrow.clockwise"
        case "trash", "trash-2": return "trash"
        case "rotate-ccw": return "arrow.uturn.backward"
        case "play": return "play.fill"
        case "video": return "play.rectangle.fill"
        case "file": return "doc"
        case "file-text": return "doc.text"
        case "image": return "photo"
        case "music": return "music.note"
        case "eye": return "eye.fill"
        case "eye-off": return "eye.slash"
        case "info": return "info.circle"
        case "settings", "sliders": return "slider.horizontal.3"
        case "network", "globe": return "network"
        case "subtitles", "message-square-text": return "captions.bubble"
        case "list": return "list.bullet"
        case "list-restart": return "arrow.counterclockwise.circle"
        case "smartphone": return "iphone"
        case "tv": return "tv"
        case "drafting-compass": return "compass.drawing"
        case "circle-check": return "checkmark.circle.fill"
        case "circle-x": return "xmark.circle.fill"
        case "package-open": return "shippingbox"
        case "monitor": return "display"
        case "wrench": return "wrench.and.screwdriver"
        case "chevron-right": return "chevron.right"
        default: return "circle"
        }
    }
}
