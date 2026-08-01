import Foundation
import RealmSwift

enum DownloadRequeueResult: Equatable {
    case failed
    case awaitingTaskCompletion
    case completedWithoutTask

    var didRequeue: Bool {
        self != .failed
    }
}
import UserNotifications

enum DownloadSupport {
    struct CompletionResult: Equatable {
        let state: Download.State
        let message: String

        var shouldDiscardArtifact: Bool {
            state == .queued || state == .stopped
        }
    }

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

    static func preconditionSerializedTransition() {
        dispatchPrecondition(condition: .onQueue(.main))
    }

    static func performSerializedTransition<Result>(_ work: @escaping () -> Result) -> Result {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    static func realm(context: String) -> Realm? {
        PutioRealm.open(context: context)
    }

    @discardableResult
    static func write(_ realm: Realm, context: String, updates: () -> Void) -> Bool {
        PutioRealm.write(realm, context: context, updates: updates)
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

    @discardableResult
    static func deleteItemIfPresent(at url: URL?, context: String) -> Bool {
        guard let url else { return true }
        return deleteItemIfPresent(at: url, context: context)
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

    static func completionResult(
        currentState: Download.State,
        error: Error?,
        artifactSaveFailureMessage: String? = nil
    ) -> CompletionResult {
        if currentState == .queued || currentState == .stopped {
            return CompletionResult(state: currentState, message: "")
        }

        if let artifactSaveFailureMessage {
            return CompletionResult(state: .failed, message: artifactSaveFailureMessage)
        }

        guard let error = error as NSError? else {
            return CompletionResult(state: .completed, message: "")
        }

        return CompletionResult(state: .failed, message: error.localizedDescription)
    }

    static func completedAt(for state: Download.State, now: Date = Date()) -> Date? {
        state == .completed ? now : nil
    }

    static func normalizedProgress(
        loadedDurations: [Double],
        expectedDuration: Double
    ) -> Double? {
        guard expectedDuration.isFinite, expectedDuration > 0 else { return nil }
        guard loadedDurations.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let progress = loadedDurations.reduce(0, +) / expectedDuration
        guard progress.isFinite else { return nil }
        return min(max(progress, 0), 1)
    }
}

enum DownloadTaskCompletionIdentity {
    private static let defaultsKeyPrefix = "DownloadTaskCompletionIdentity.current"

    static func begin(
        downloadID: Int,
        fileType: Download.FileType,
        defaults: UserDefaults = .standard
    ) -> String {
        let taskDescription = "\(downloadID):\(UUID().uuidString)"
        adopt(
            taskDescription: taskDescription,
            downloadID: downloadID,
            fileType: fileType,
            defaults: defaults
        )
        return taskDescription
    }

    static func parsedDownloadID(from taskDescription: String?) -> Int? {
        guard let idComponent = taskDescription?.split(separator: ":", maxSplits: 1).first else { return nil }
        return Int(idComponent)
    }

    static func adopt(
        taskDescription: String,
        downloadID: Int,
        fileType: Download.FileType,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(taskDescription, forKey: defaultsKey(downloadID: downloadID, fileType: fileType))
    }

    static func preferredTaskDescription(
        from taskDescriptions: [String],
        downloadID: Int,
        fileType: Download.FileType,
        defaults: UserDefaults = .standard
    ) -> String? {
        let currentDescription = defaults.string(
            forKey: defaultsKey(downloadID: downloadID, fileType: fileType)
        )
        if let currentDescription {
            return taskDescriptions.contains(currentDescription) ? currentDescription : nil
        }
        let legacyDescription = String(downloadID)
        return taskDescriptions.contains(legacyDescription) ? legacyDescription : nil
    }

    static func drainingDownloadID(taskIdentifier: Int, fileType: Download.FileType) -> Int {
        let mediaOffset = fileType == .audio ? 1 : 2
        return -(taskIdentifier * 2 + mediaOffset)
    }

    static func downloadID(
        mappedID: Int?,
        taskDescription: String?,
        fileType: Download.FileType,
        defaults: UserDefaults = .standard
    ) -> Int? {
        guard let taskDescription,
              let parsedID = parsedDownloadID(from: taskDescription),
              mappedID == nil || mappedID == parsedID else { return nil }
        let expectedDescription = defaults.string(
            forKey: defaultsKey(downloadID: parsedID, fileType: fileType)
        )
        if let expectedDescription {
            return expectedDescription == taskDescription ? parsedID : nil
        }
        return mappedID != nil || taskDescription == String(parsedID) ? parsedID : nil
    }

    static func clearIfCurrent(
        taskDescription: String?,
        downloadID: Int,
        fileType: Download.FileType,
        defaults: UserDefaults = .standard
    ) {
        let key = defaultsKey(downloadID: downloadID, fileType: fileType)
        guard defaults.string(forKey: key) == taskDescription else { return }
        defaults.removeObject(forKey: key)
    }

    static func clear(
        downloadID: Int,
        fileType: Download.FileType,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: defaultsKey(downloadID: downloadID, fileType: fileType))
    }

    private static func defaultsKey(downloadID: Int, fileType: Download.FileType) -> String {
        "\(defaultsKeyPrefix).\(fileType.rawValue).\(downloadID)"
    }
}

enum DownloadTaskRestorationPolicy {
    enum Action: Equatable {
        case restore
        case cancelPreservingState
        case cancelIgnoringCompletion
    }

    static func action(for state: Download.State) -> Action {
        switch state {
        case .starting, .active:
            return .restore
        case .queued:
            return .cancelPreservingState
        case .completed, .failed, .stopped:
            return .cancelIgnoringCompletion
        }
    }
}

final class DownloadAttemptRegistry {
    struct Token: Equatable {
        fileprivate let value = UUID()
    }

    private let lock = NSLock()
    private var tokens = [Int: Token]()

    func begin(downloadID: Int) -> Token {
        lock.lock()
        defer { lock.unlock() }
        let token = Token()
        tokens[downloadID] = token
        return token
    }

    func consume(_ token: Token, downloadID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard tokens[downloadID] == token else { return false }
        tokens.removeValue(forKey: downloadID)
        return true
    }

    func isCurrent(_ token: Token, downloadID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tokens[downloadID] == token
    }

    func invalidate(downloadID: Int) {
        lock.lock()
        tokens.removeValue(forKey: downloadID)
        lock.unlock()
    }
}
