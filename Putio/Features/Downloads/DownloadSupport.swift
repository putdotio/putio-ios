import Foundation
import RealmSwift
import UserNotifications

enum DownloadSupport {
    static func realm(context: String) -> Realm? {
        PutioRealm.open(context: context)
    }

    @discardableResult
    static func write(_ realm: Realm, context: String, updates: () -> Void) -> Bool {
        PutioRealm.write(realm, context: context, updates: updates)
    }

    static func url(from string: String, context: String) -> URL? {
        guard let url = URL(string: string) else {
            log.error("[DownloadSupport] \(context): invalid URL \(string)")
            return nil
        }

        return url
    }

    static func absoluteDocumentsURL(for relativePath: String) -> URL? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            log.error("[DownloadSupport] Unable to resolve documents directory")
            return nil
        }

        return documentsURL.appendingPathComponent(relativePath)
    }

    @discardableResult
    static func deleteItemIfPresent(at url: URL, context: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return true
        }

        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            log.error("[DownloadSupport] \(context): \(error.localizedDescription)")
            return false
        }
    }

    static func enqueueCompletedDownloadNotification(for downloadName: String) {
        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = NSLocalizedString("Download Completed!", comment: "")
        notificationContent.body = String(
            format: NSLocalizedString("%@ is ready to play.", comment: ""),
            downloadName
        )

        let notificationTrigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let notificationRequest = UNNotificationRequest(
            identifier: DOWNLOAD_LOCAL_NOTIFICATION_IDENTIFIER,
            content: notificationContent,
            trigger: notificationTrigger
        )

        UNUserNotificationCenter.current().add(notificationRequest) { error in
            guard let error else { return }
            log.error("[DownloadSupport] Failed to enqueue completion notification: \(error.localizedDescription)")
        }
    }
}
