import CoreText
import UIKit

// The licensed faces are fetched by `mise run fonts-setup` and bundled by a
// build phase, so a build can legitimately lack them. Nothing here fails on
// that: `sans`/`mono` substitute the system font, while the `IfAvailable`
// variants return nil so a caller can leave existing styling alone.
enum BrandFont {
    private static let sansFamily = "GT America"
    // CoreText reports the variable OTF's internal family name, not the
    // "Berkeley Mono" alias the web @font-face declares.
    private static let monoFamily = "Berkeley Mono Variable"

    private static var didAttemptRegistration = false

    static func registerIfAvailable() {
        guard !didAttemptRegistration else { return }
        didAttemptRegistration = true

        // Mirrors the build phase's copy/clean glob, so a stray OTF from
        // another resource bundle is never registered as a side effect.
        let urls = (Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("gt-america-") || name.hasPrefix("berkeley-mono-")
            }
        guard !urls.isEmpty else { return }

        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { errors, _ in
            // Present-but-broken has to be distinguishable from the accepted
            // fonts-absent degradation, which is silent.
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

    // The `IfAvailable` variants return nil rather than a system substitute, so
    // a caller can leave existing styling untouched instead of swapping in a
    // face with different metrics.
    static func sansIfAvailable(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont? {
        brandFont(family: sansFamily, size: size, weight: weight)
    }

    // A single variable OTF, so the weight comes from the wght axis rather than
    // a named face — unlike sans below.
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

    // Lets the appearance hooks stay idempotent — see
    // UILabel.applyBrandFontIfAvailable.
    static func isBrandFace(_ font: UIFont) -> Bool {
        font.familyName == sansFamily || font.familyName == monoFamily
    }

    private static func brandFont(family: String, size: CGFloat, weight: UIFont.Weight) -> UIFont? {
        // Accessors must not depend on AppDelegate call order.
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
