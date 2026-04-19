import Foundation

private func appSetting(_ key: String, fallback: String = "") -> String {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
        return fallback
    }

    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

let APP_STORE_APP_ID = "id1260479699"
let APP_RUNTIME_IDENTIFIER = appSetting("PUTIO_APP_IDENTIFIER", fallback: "com.putio.opensource.ios")
let PUTIOKIT_CLIENT_ID = appSetting("PUTIO_OAUTH_CLIENT_ID", fallback: "3001")
let CHROMECAST_RECEIVER_APP_ID = appSetting("PUTIO_CHROMECAST_RECEIVER_APP_ID", fallback: "CC1AD845")
let INTERCOM_API_KEY = appSetting("PUTIO_INTERCOM_API_KEY")
let INTERCOM_APP_ID = appSetting("PUTIO_INTERCOM_APP_ID")
let SENTRY_DSN = appSetting("PUTIO_SENTRY_DSN")

let APP_KEYCHAIN_SERVICE = APP_RUNTIME_IDENTIFIER
let DOWNLOAD_VIDEO_BACKGROUND_SESSION_IDENTIFIER = "\(APP_RUNTIME_IDENTIFIER).background.video"
let DOWNLOAD_AUDIO_BACKGROUND_SESSION_IDENTIFIER = "\(APP_RUNTIME_IDENTIFIER).background.audio"
let DOWNLOAD_LEGACY_BACKGROUND_SESSION_IDENTIFIER = "\(APP_RUNTIME_IDENTIFIER).background.legacy"
let DOWNLOAD_LOCAL_NOTIFICATION_IDENTIFIER = "\(APP_RUNTIME_IDENTIFIER).local-notification.download"

let INTERCOM_ENABLED = !INTERCOM_API_KEY.isEmpty && !INTERCOM_APP_ID.isEmpty
let SENTRY_ENABLED = !SENTRY_DSN.isEmpty
