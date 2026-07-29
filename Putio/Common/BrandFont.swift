import CoreText
import UIKit

// Licensed brand fonts are optional: fetched at dev time via
// `mise run fonts-setup`, bundled by a build phase, and registered here at
// launch. Every accessor falls back to the system font when the face is absent.
// Verify builds do bundle them (`PUTIO_BUNDLE_BRAND_FONTS = YES` in
// Config/Verify.xcconfig), so snapshot baselines are recorded and compared with
// real brand typography.
enum BrandFont {
    private static let sansFamily = "GT America"
    // iOS registers the variable OTF under its internal family name; the web
    // @font-face aliases it to "Berkeley Mono", but CoreText uses the real name.
    private static let monoFamily = "Berkeley Mono Variable"

    private static var didAttemptRegistration = false

    static func registerIfAvailable() {
        guard !didAttemptRegistration else { return }
        didAttemptRegistration = true

        // Scoped to the synced brand set (mirrors the build phase's
        // gt-america-*/berkeley-mono-*.otf copy/clean glob) so a stray OTF from
        // another resource bundle never gets registered as a side effect.
        let urls = (Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("gt-america-") || name.hasPrefix("berkeley-mono-")
            }
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

    // Berkeley Mono is the design system's only mono face: every numeric
    // (sizes, ETAs, counts) plus identifiers, tokens, and other
    // machine-readable strings. It ships as a single variable OTF, so the
    // weight comes from the weight trait (the wght axis), not a named face.
    static func monoIfAvailable(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont? {
        registerIfAvailable()

        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: monoFamily,
            .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        let font = UIFont(descriptor: descriptor, size: size)
        // UIFont(descriptor:) falls back silently; confirm the family resolved.
        return font.familyName == monoFamily ? font : nil
    }

    // Whether a font is already one of the licensed faces. Lets the appearance
    // hooks stay idempotent: they run more than once per label, and re-deriving
    // size and weight from an already-branded descriptor loses the weight trait.
    static func isBrandFace(_ font: UIFont) -> Bool {
        font.familyName == sansFamily || font.familyName == monoFamily
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
