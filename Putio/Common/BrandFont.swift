import CoreText
import UIKit

// Licensed brand fonts are optional: fetched at dev time via
// `make fonts-setup`, bundled by a build phase (never in Verify builds so
// snapshot baselines stay on system fonts), and registered here at launch.
// Every accessor falls back to the system font when the face is absent.
enum BrandFont {
    private static let sansFamily = "GT America"
    private static let monoFamily = "GT America Mono"

    private static var didAttemptRegistration = false

    static func registerIfAvailable() {
        guard !didAttemptRegistration else { return }
        didAttemptRegistration = true

        // Scoped to the synced brand set (mirrors the build phase's
        // gt-america-*.otf copy/clean glob) so a stray OTF from another
        // resource bundle never gets registered as a side effect.
        let urls = (Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("gt-america-") }
        guard !urls.isEmpty else { return }

        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { errors, _ in
            // Fonts present but broken must be distinguishable from the
            // accepted fonts-absent degradation: log which faces failed so
            // a corrupt file or registration conflict leaves a trace.
            for case let error as NSError in errors as NSArray as? [Error] ?? [] {
                let failed = (error.userInfo[kCTFontManagerErrorFontURLsKey as String] as? [URL] ?? [])
                    .map(\.lastPathComponent)
                    .joined(separator: ", ")
                InternalFailurePresenter.log(
                    "BrandFont: registration failed for [\(failed)]: \(error.localizedDescription)"
                )
            }
            return true // keep registering the remaining faces
        }
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
        // Accessors must not depend on AppDelegate call order; registration
        // is attempted at most once, so this is a cheap guard thereafter.
        registerIfAvailable()

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
