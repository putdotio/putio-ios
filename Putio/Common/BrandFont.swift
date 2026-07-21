import UIKit

// Licensed brand fonts are optional: fetched at dev time via
// `make fonts-setup`, bundled by a build phase (never in Verify builds so
// snapshot baselines stay on system fonts), and registered here at launch.
// Every accessor falls back to the system font when the face is absent.
enum BrandFont {
    private static let sansFamily = "GT America"
    private static let monoFamily = "GT America Mono"

    private static var isRegistered = false

    static func registerIfAvailable() {
        guard !isRegistered else { return }

        let urls = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? []
        guard !urls.isEmpty else { return }

        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        isRegistered = true
    }

    static func sans(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        sansIfAvailable(size: size, weight: weight)
            ?? .systemFont(ofSize: size, weight: weight)
    }

    static func mono(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        monoIfAvailable(size: size, weight: weight)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    // Optional variants let callers leave system styling completely untouched
    // when the brand faces are absent (e.g. verification builds), instead of
    // substituting a system font with slightly different metrics.
    static func sansIfAvailable(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont? {
        brandFont(family: sansFamily, size: size, weight: weight)
    }

    static func monoIfAvailable(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont? {
        brandFont(family: monoFamily, size: size, weight: weight)
    }

    private static func brandFont(family: String, size: CGFloat, weight: UIFont.Weight) -> UIFont? {
        let face: String
        switch weight {
        case .black, .heavy:
            face = "Black"
        case .bold, .semibold:
            face = "Bold"
        case .medium:
            face = "Medium"
        default:
            face = "Regular"
        }

        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            .face: face
        ])

        let font = UIFont(descriptor: descriptor, size: size)
        // UIFont(descriptor:) falls back silently; confirm the family resolved.
        return font.familyName == family ? font : nil
    }
}
