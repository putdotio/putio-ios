import UIKit

enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark

    var style: UIUserInterfaceStyle {
        switch self {
        case .system:
            return .unspecified
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var label: String {
        switch self {
        case .system:
            return NSLocalizedString("System", comment: "")
        case .light:
            return NSLocalizedString("Light", comment: "")
        case .dark:
            return NSLocalizedString("Dark", comment: "")
        }
    }
}

enum AppearanceManager {
    static let defaultsKey = "putio.appearance"

    static var current: AppAppearance {
        get {
            #if DEBUG
            if let forced = ProcessInfo.processInfo.environment["PUTIO_E2E_APPEARANCE"]
                .flatMap(AppAppearance.init(rawValue:)) {
                return forced
            }
            #endif

            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let appearance = AppAppearance(rawValue: raw) else {
                return .system
            }

            return appearance
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    @MainActor
    static func apply(to window: UIWindow?) {
        window?.overrideUserInterfaceStyle = current.style
    }
}
