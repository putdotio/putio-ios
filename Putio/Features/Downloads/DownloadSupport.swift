import Foundation
import RealmSwift
import UserNotifications

enum DownloadSupport {
    enum LocalFileLocation: Equatable {
        case none
        case unresolved
        case resolved(URL)
    }

    enum LocalFileDeletionResult: Equatable {
        case noLocation
        case unresolvedLocation
        case alreadyMissing
        case removed
        case failed
    }

    static func realm(context: String) -> Realm? {
        PutioRealm.open(context: context)
    }

    @discardableResult
    static func write(_ realm: Realm, context: String, updates: () -> Void) -> Bool {
        var attempt = 0
        return performWithOneRetry {
            defer { attempt += 1 }
            let attemptContext = attempt == 0 ? context : "\(context).retry"
            return PutioRealm.write(realm, context: attemptContext, updates: updates)
        }
    }

    static func performWithOneRetry(_ operation: () -> Bool) -> Bool {
        if operation() { return true }
        return operation()
    }

    @discardableResult
    static func releaseAfterPersistence(_ didPersist: Bool, release: () -> Void) -> Bool {
        guard didPersist else { return false }
        release()
        return true
    }

    static func deleteRecord(id: Int, context: String) -> Bool {
        guard let realm = realm(context: context) else { return false }
        guard let download = realm.object(ofType: Download.self, forPrimaryKey: id) else {
            return true
        }

        return write(realm, context: "\(context).write") {
            realm.delete(download)
        }
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

    static func localFileLocation<Value>(
        from persistedValue: Any?,
        as _: Value.Type,
        resolve: (Value) -> URL?
    ) -> LocalFileLocation {
        guard let persistedValue else { return .none }
        guard let value = persistedValue as? Value else { return .unresolved }
        guard let url = resolve(value) else { return .unresolved }
        return .resolved(url)
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

    static func copyDownloadedArtifact(from sourceURL: URL, to destinationURL: URL) -> Error? {
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
            return nil
        } catch {
            return error
        }
    }

    static func deleteLocalFile(
        at location: LocalFileLocation,
        context: String
    ) -> LocalFileDeletionResult {
        let url: URL
        switch location {
        case .none:
            return .noLocation
        case .unresolved:
            return .unresolvedLocation
        case .resolved(let resolvedURL):
            url = resolvedURL
        }

        do {
            try FileManager.default.removeItem(at: url)
            return .removed
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return .alreadyMissing
        } catch {
            log.error("[DownloadSupport] \(context): \(error.localizedDescription)")
            return .failed
        }
    }

    static func performDeletion(
        state: Download.State?,
        cancelActiveDownload: () -> Void,
        deleteLocalFile: () -> LocalFileDeletionResult,
        deleteRecord: () -> Bool,
        localFileDeletionDidSucceed: () -> Void = {}
    ) -> Bool {
        guard let state else { return false }

        var localFileResult: LocalFileDeletionResult?
        switch state {
        case .queued, .starting, .active:
            cancelActiveDownload()
        case .completed:
            let result = deleteLocalFile()
            guard result == .removed || result == .alreadyMissing else { return false }
            localFileResult = result
        case .failed, .stopped:
            let result = deleteLocalFile()
            guard result != .unresolvedLocation && result != .failed else { return false }
            localFileResult = result
        }

        guard deleteRecord() else { return false }
        if localFileResult == .removed || localFileResult == .alreadyMissing {
            localFileDeletionDidSucceed()
        }
        return true
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
