import SwiftUI

/// SF Symbol icon, keyed by the same name strings the React Native tv-native
/// reference uses for its Lucide icons. Keeping the call-site vocabulary tied
/// to the spec — actual rendering swaps to SF Symbols since they're the
/// native-feeling primitive on tvOS and avoid SVG / vector-data plumbing.
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

    static func symbol(for name: String) -> String {
        switch name {
        case "folder", "folder-closed":     return "folder.fill"
        case "folder-open":                 return "folder.fill"
        case "search":                      return "magnifyingglass"
        case "history":                     return "clock.arrow.circlepath"
        case "user":                        return "person.crop.circle"
        case "log-out":                     return "rectangle.portrait.and.arrow.right"
        case "refresh-ccw":                 return "arrow.clockwise"
        case "arrow-down-wide-narrow":      return "arrow.up.and.down.text.horizontal"
        case "trash", "trash-2":            return "trash"
        case "recycle":                     return "arrow.3.trianglepath"
        case "rotate-ccw":                  return "arrow.uturn.backward"
        case "play":                        return "play.fill"
        case "monitor-play", "video":       return "play.rectangle.fill"
        case "film":                        return "film"
        case "file":                        return "doc"
        case "file-text":                   return "doc.text"
        case "file-video":                  return "video"
        case "image":                       return "photo"
        case "music":                       return "music.note"
        case "eye":                         return "eye.fill"
        case "eye-off":                     return "eye.slash"
        case "info":                        return "info.circle"
        case "settings", "sliders":         return "slider.horizontal.3"
        case "sliders-horizontal":          return "slider.horizontal.3"
        case "network":                     return "network"
        case "subtitles", "captions",
             "message-square-text":         return "captions.bubble"
        case "message-square-off":          return "captions.bubble.fill"
        case "circle-check", "check-circle-2": return "checkmark.circle.fill"
        case "check":                       return "checkmark"
        case "circle-x", "x-circle":        return "xmark.circle.fill"
        case "box", "package-open":         return "shippingbox"
        case "hard-drive":                  return "internaldrive"
        case "monitor":                     return "display"
        case "tv", "tv-2":                  return "tv"
        case "headphones":                  return "headphones"
        case "smartphone":                  return "iphone"
        case "drafting-compass":            return "compass.drawing"
        case "chevron-right":               return "chevron.right"
        case "chevron-down":                return "chevron.down"
        case "bug":                         return "ant"
        default:                            return "circle"
        }
    }
}
