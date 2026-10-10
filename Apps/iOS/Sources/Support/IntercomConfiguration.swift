import Foundation

/// The support messenger's workspace keys, read from build settings through
/// Info.plist. Nil is the kill switch: `PUTIO_INTERCOM_ENABLED` other than
/// `YES`, or an empty key, which the checked-in defaults are.
struct IntercomConfiguration: Equatable {
  let apiKey: String
  let appID: String

  init?(bundle: Bundle = .main) {
    self.init(info: bundle.infoDictionary ?? [:])
  }

  init?(info: [String: Any]) {
    func value(_ key: String) -> String? {
      let value = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      // An unset build setting can arrive as its literal `$(NAME)` placeholder.
      return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
    guard value("PUTIO_INTERCOM_ENABLED") == "YES",
      let apiKey = value("PUTIO_INTERCOM_API_KEY"),
      let appID = value("PUTIO_INTERCOM_APP_ID")
    else { return nil }
    self.apiKey = apiKey
    self.appID = appID
  }
}
