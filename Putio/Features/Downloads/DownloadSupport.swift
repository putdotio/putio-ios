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

    enum ArtifactSaveError: Error, Equatable {
        case httpStatus(Int)
        case unresolvedDestination
        case unsupportedMediaType
    }

    static func realm(context: PutioRealm.Context) -> Realm? {
        PutioRealm.open(context: context)
    }

    @discardableResult
    static func write(_ realm: Realm, context: PutioRealm.Context, updates: () -> Void) -> Bool {
        var attempt = 0
        return performWithOneRetry {
            defer { attempt += 1 }
            let attemptContext = attempt == 0 ? context : context.appending("retry")
            return PutioRealm.write(realm, context: attemptContext, updates: updates)
        }
    }

    static let recordQueue = DispatchQueue(label: "com.putio.downloads.records", qos: .userInitiated)

    static func createRecord(
        id: Int,
        context: PutioRealm.Context,
        makeDownload: @escaping () -> Download?,
        didCreate: @escaping () -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let queueController = DownloadQueueController.sharedInstance
        let token = queueController.recordCreationWillStart(id: id)
        recordQueue.async {
            let didWrite = autoreleasepool { () -> Bool in
                guard let download = makeDownload(), let realm = realm(context: context) else { return false }
                var isCurrent = false
                let didCommit = write(realm, context: context.appending("write")) {
                    isCurrent = queueController.isRecordCreationCurrent(token)
                    guard isCurrent else { return }
                    realm.add(download, update: .all)
                }
                return didCommit && isCurrent
            }
            DispatchQueue.main.async {
                if didWrite {
                    realm(context: context.appending("refresh"))?.refresh()
                    didCreate()
                }
                queueController.recordCreationDidFinish(id: id, didWrite: didWrite)
            }
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

    static func deleteRecord(id: Int, context: PutioRealm.Context, ifStateIs expectedState: Download.State? = nil) -> Bool {
        guard let realm = realm(context: context) else { return false }
        guard realm.object(ofType: Download.self, forPrimaryKey: id) != nil else {
            return true
        }

        var stateMatched = true
        let didWrite = write(realm, context: context.appending("write")) {
            guard let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return }
            stateMatched = expectedState.map { download.state == $0 } ?? true
            guard stateMatched else { return }
            realm.delete(download)
        }
        return didWrite && stateMatched
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

    static func saveDownloadedArtifact(response: URLResponse?, from sourceURL: URL, to destinationURL: URL?) -> Error? {
        if let error = statusError(of: response) { return error }
        guard let destinationURL else { return ArtifactSaveError.unresolvedDestination }
        return copyDownloadedArtifact(from: sourceURL, to: destinationURL)
    }

    static func statusError(of response: URLResponse?) -> ArtifactSaveError? {
        guard let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) else { return nil }
        return .httpStatus(response.statusCode)
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

    static func moveAsideForDeletion(_ location: LocalFileLocation) -> LocalFileLocation {
        guard case .resolved(let url) = location else { return location }
        let asideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.moveItem(at: url, to: asideURL)
            return .resolved(asideURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return .none
        } catch {
            log.error("[DownloadSupport] moveAsideForDeletion: \(error.localizedDescription)")
            return .unresolved
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

    static let deletionQueue = DispatchQueue(label: "com.putio.downloads.deletion", qos: .userInitiated)

    enum RecordLookup: Equatable {
        case missing
        case stored(Download.State)
        case unreadable
    }

    struct Deletion {
        let state: Download.State?
        let cancelActiveDownload: () -> Void
        let deleteLocalFile: () -> LocalFileDeletionResult
        let currentState: () -> RecordLookup
        let deleteRecord: (_ expectedState: Download.State?) -> Bool
        let localFileDeletionDidSucceed: () -> Void

        func perform(completion: @escaping (Bool) -> Void) {
            guard runsOnDeletionQueue else { return completion(performNow()) }
            deletionQueue.async {
                let didDelete = autoreleasepool(invoking: performFinished)
                DispatchQueue.main.async { completion(didDelete) }
            }
        }

        private var runsOnDeletionQueue: Bool {
            switch state {
            case .completed, .failed, .stopped: return true
            case .queued, .starting, .active, nil: return false
            }
        }

        private func performNow() -> Bool {
            performDeletion(
                state: state,
                cancelActiveDownload: cancelActiveDownload,
                deleteLocalFile: deleteLocalFile,
                deleteRecord: { deleteRecord(nil) },
                localFileDeletionDidSucceed: localFileDeletionDidSucceed
            )
        }

        private func performFinished() -> Bool {
            switch currentState() {
            case .missing: return true
            case .unreadable: return false
            case .stored(let current): guard current == state else { return false }
            }
            return performDeletion(
                state: state,
                cancelActiveDownload: cancelActiveDownload,
                deleteLocalFile: deleteLocalFile,
                deleteRecord: { deleteRecord(state) },
                localFileDeletionDidSucceed: localFileDeletionDidSucceed
            )
        }
    }

    static func deletion(
        id: Int,
        state: Download.State?,
        context: PutioRealm.Context,
        cancelActiveDownload: @escaping () -> Void,
        deleteLocalFile: @escaping () -> LocalFileDeletionResult
    ) -> Deletion {
        Deletion(
            state: state,
            cancelActiveDownload: cancelActiveDownload,
            deleteLocalFile: deleteLocalFile,
            currentState: {
                guard let realm = realm(context: context.appending("currentState")) else { return .unreadable }
                realm.refresh()
                return realm.object(ofType: Download.self, forPrimaryKey: id).map { .stored($0.state) } ?? .missing
            },
            deleteRecord: { expectedState in
                deleteRecord(id: id, context: context, ifStateIs: expectedState)
            },
            localFileDeletionDidSucceed: {
                UserDefaults.standard.removeObject(forKey: String(id))
            }
        )
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

extension AnalyticsEvent.Media {
    init(_ fileType: Download.FileType) {
        switch fileType {
        case .video: self = .video
        case .audio: self = .audio
        }
    }
}

extension AnalyticsEvent.PlaybackError {
    init(downloadError error: Error?) {
        switch error as? DownloadSupport.ArtifactSaveError {
        case .httpStatus(let status)?: self.init(httpStatus: status)
        case .unsupportedMediaType?: self = .unsupported
        case .unresolvedDestination?, nil: self.init(error)
        }
    }
}
