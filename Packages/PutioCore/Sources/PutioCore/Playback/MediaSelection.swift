import Foundation

#if !os(watchOS)
  import AVFoundation
#endif

/// Language codes of audio and subtitle options, normalised so "eng",
/// "en-US", and "en" compare equal, and the selection reads the harness and
/// the offline store share.
public enum PutioMediaSelection {
  public static func languageCode(_ raw: String) -> String {
    (Locale(identifier: raw).language.languageCode?.identifier ?? raw).lowercased()
  }

  public static func matches(_ lhs: String, _ rhs: String) -> Bool {
    languageCode(lhs) == languageCode(rhs)
  }

  /// The index of the first preferred language present, or nil when none
  /// is: playback then keeps the asset's own default.
  public static func match(in codes: [String], preferredLanguages: [String]) -> Int? {
    for language in preferredLanguages {
      if let index = codes.firstIndex(where: { matches($0, language) }) { return index }
    }
    return nil
  }

  #if !os(watchOS)
    public static func languageCode(of option: AVMediaSelectionOption) -> String {
      languageCode(option.extendedLanguageTag ?? option.locale?.identifier ?? "und")
    }

    /// The subtitles a viewer can pick; forced-only renditions play on
    /// their own and never show in a menu.
    public static func subtitleOptions(of group: AVMediaSelectionGroup) -> [AVMediaSelectionOption] {
      group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
    }

    @MainActor
    public static func selectedAudioLanguage(in item: AVPlayerItem) async -> String? {
      guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
        let option = item.currentMediaSelection.selectedMediaOption(in: group)
      else { return nil }
      return languageCode(of: option)
    }

    /// The legible option's language, `off` when the stream offers subtitles
    /// but none is selected, or `unavailable` when it offers none.
    @MainActor
    public static func selectedSubtitle(in item: AVPlayerItem) async -> String {
      guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
        return "unavailable"
      }
      guard let option = item.currentMediaSelection.selectedMediaOption(in: group) else {
        return "off"
      }
      return languageCode(of: option)
    }

    /// Offline assets keep every downloaded language; the player picks the
    /// first preferred one present and otherwise leaves the asset's default.
    @MainActor
    public static func selectAudio(preferring languages: [String], in item: AVPlayerItem) async {
      guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
        let index = match(
          in: group.options.map { languageCode(of: $0) }, preferredLanguages: languages)
      else { return }
      item.select(group.options[index], in: group)
    }
  #endif
}
