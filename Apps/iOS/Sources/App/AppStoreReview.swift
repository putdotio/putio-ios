import Foundation

/// The "Rate put.io on App Store" destination. The listing comes from the
/// `PUTIO_APP_STORE_ID` build setting so a new App Store record needs no
/// source change; an unset or malformed value falls back to the 3.x listing.
enum PutioAppStoreReview {
  static let fallbackAppID = "1260479699"

  static func url(bundle: Bundle = .main) -> URL? {
    url(appID: bundle.object(forInfoDictionaryKey: "PUTIO_APP_STORE_ID") as? String)
  }

  static func url(appID configured: String?) -> URL? {
    let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let appID = isValid(trimmed) ? trimmed : fallbackAppID
    return URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")
  }

  /// App Store IDs are all digits; this also rejects an unexpanded
  /// `$(PUTIO_APP_STORE_ID)` placeholder.
  static func isValid(_ candidate: String) -> Bool {
    !candidate.isEmpty && candidate.utf8.allSatisfy { (48...57).contains($0) }
  }
}
