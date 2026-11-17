import Foundation

enum PutioOfflineLanguage {
  /// The first preferred language present, or nil when none is: playback
  /// uses nil to keep the asset's own default.
  static func match(from stored: [PutioOfflineTrack], preferredLanguages: [String])
    -> PutioOfflineTrack?
  {
    for language in preferredLanguages {
      let base = normalize(language)
      if let match = stored.first(where: { matches($0.languageCode, base) }) { return match }
    }
    return nil
  }

  static func matches(_ code: String, _ base: String) -> Bool {
    normalize(code) == normalize(base)
  }

  static func normalize(_ code: String) -> String {
    (Locale(identifier: code).language.languageCode?.identifier ?? code).lowercased()
  }
}
