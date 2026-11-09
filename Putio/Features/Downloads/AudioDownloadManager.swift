import Foundation
import AVFoundation
import RealmSwift
import UserNotifications
import NotificationCenter
import PutioSDK

class AudioDownloadManager: NSObject, DownloadQueueManaging {
    static let sharedInstance = AudioDownloadManager()
    static let NOTIFICATION = Notification.Name("DOWNLOAD_MANAGER_QUEUE_UPDATED")

    fileprivate var urlSession: URLSession!
    fileprivate var activeDownloadsMap = [URLSessionTask: Int]()
    private let activeDownloadsLock = NSLock()
    fileprivate var lastProgressUpdateTime = [Int: CFAbsoluteTime]()
    private var artifactSaveErrors = [URLSessionTask: Error]()
    private let startTimings = DownloadStartTimings()

    var activeDownloadCount: Int {
        withActiveDownloadsMap { $0.count }
    }

    var activeDownloadIDs: Set<Int> {
        withActiveDownloadsMap { Set($0.values) }
    }

    override private init() {
        super.init()

        let backgroundConfiguration = URLSessionConfiguration.background(withIdentifier: DOWNLOAD_AUDIO_BACKGROUND_SESSION_IDENTIFIER)
        backgroundConfiguration.sessionSendsLaunchEvents = true

        urlSession = URLSession(
            configuration: backgroundConfiguration,
            delegate: self,
            delegateQueue: .main
        )

        restore()
    }

    private func restore() {
        urlSession.getAllTasks { (tasks) in
            log.verbose("ADM: restore - task count: \(tasks.count)")
            DownloadQueueController.sharedInstance.managerDidRestore(.audio, activeIDs: self.restore(tasks))
        }
    }

    func restore(_ tasks: [URLSessionTask]) -> Set<Int> {
        var restoredIDs = Set<Int>()
        tasks.forEach { task in
            guard let description = task.taskDescription,
                  let id = Int(description),
                  task.state == .running || task.state == .suspended || (task.state == .completed && task.error == nil),
                  let download = getDownloadFromDatabase(id: id),
                  download.state == .starting || download.state == .active,
                  !restoredIDs.contains(id) else {
                task.cancel()
                return
            }
            if task.state == .running { task.suspend() }
            withActiveDownloadsMap { $0[task] = id }
            restoredIDs.insert(id)
        }
        return restoredIDs
    }

    private func downloadID(for task: URLSessionTask, error: Error? = nil) -> Int? {
        if let id = withActiveDownloadsMap({ $0[task] }) { return id }
        guard error == nil,
              let description = task.taskDescription,
              let id = Int(description),
              !activeDownloadIDs.contains(id),
              let download = getDownloadFromDatabase(id: id),
              download.state == .starting || download.state == .active else { return nil }
        return id
    }

    private func notifyUser(for id: Int) {
        guard let download = getDownloadFromDatabase(id: id) else { return }
        DownloadSupport.enqueueCompletedDownloadNotification(for: download.name)
    }

    private func getDownloadFromDatabase(id: Int) -> Download? {
        guard let realm = DownloadSupport.realm(context: "AudioDownloadManager.getDownloadFromDatabase") else {
            return nil
        }

        return realm.object(ofType: Download.self, forPrimaryKey: id)
    }

    func beginDownload(id: Int) {
        guard let download = getDownloadFromDatabase(id: id) else {
            DownloadQueueController.sharedInstance.startFailed(id: id)
            return
        }
        guard download.state == .starting else { return }
        startTimings.begin(id: id)
        guard let url = api.audioStreamURL(fileID: download.id) else {
            startTimings.end(id: id, outcome: .failed)
            DownloadQueueController.sharedInstance.startFailed(id: id)
            return
        }

        let task = urlSession.downloadTask(with: url)

        withActiveDownloadsMap { $0[task] = id }

        task.taskDescription = String(id)
        task.resume()

        NotificationCenter.default.post(name: AudioDownloadManager.NOTIFICATION, object: nil)
    }

    @discardableResult
    func createDownload(from file: PutioFile) -> Bool {
        guard file.type == .audio else { return false }

        discardDownload(id: file.id)
        let session = AccountNoticeStore.shared.session
        return DownloadSupport.createRecord(
            id: file.id,
            context: "AudioDownloadManager.createDownload",
            makeDownload: { Download(file: file, url: "") },
            didCreate: { ProductAnalytics.capture(.downloadStarted(.audio), startedIn: session) }
        )
    }

    func cancelDownload(id: Int) {
        DownloadQueueController.sharedInstance.invalidateRecordCreations(id: id)
        guard let download = getDownloadFromDatabase(id: id) else { return }
        guard let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "AudioDownloadManager.cancelDownload.write") {
            download.progress = "0"
            download.state = .stopped
        }
        guard didWrite else { return }

        discardDownload(id: id)
        _ = deleteLocalFile(for: id)
        NotificationCenter.default.post(name: AudioDownloadManager.NOTIFICATION, object: nil)
        DownloadQueueController.sharedInstance.managerDidFinish()
    }

    func deleteDownload(id: Int, completion: @escaping (Bool) -> Void) {
        DownloadQueueController.sharedInstance.invalidateRecordCreations(id: id)
        deletion(for: id).perform { didDelete in
            self.finishDeletion(id: id, didDelete: didDelete)
            completion(didDelete)
        }
    }

    private func deletion(for id: Int) -> DownloadSupport.Deletion {
        dispatchPrecondition(condition: .onQueue(.main))
        return DownloadSupport.deletion(
            id: id,
            state: getDownloadFromDatabase(id: id)?.state,
            context: "AudioDownloadManager.deleteDownload",
            cancelActiveDownload: { self.cancelDownload(id: id) },
            deleteLocalFile: { self.deleteLocalFile(for: id) }
        )
    }

    private func finishDeletion(id: Int, didDelete: Bool) {
        guard didDelete else { return }
        discardDownload(id: id)
        DownloadQueueController.sharedInstance.managerDidFinish()
    }

    @discardableResult
    func removeDownloadRecord(id: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        DownloadQueueController.sharedInstance.invalidateRecordCreations(id: id)
        guard DownloadSupport.deleteRecord(
            id: id,
            context: "AudioDownloadManager.removeDownloadRecord"
        ) else {
            return false
        }

        discardDownload(id: id)
        UserDefaults.standard.removeObject(forKey: String(id))
        DownloadQueueController.sharedInstance.managerDidFinish()
        return true
    }

    private func withActiveDownloadsMap<Result>(
        _ body: (inout [URLSessionTask: Int]) -> Result
    ) -> Result {
        activeDownloadsLock.lock()
        defer { activeDownloadsLock.unlock() }
        return body(&activeDownloadsMap)
    }

    func restartDownload(id: Int) {
        log.verbose(["ADM: restartDownload", id])
        guard let download = getDownloadFromDatabase(id: id) else { return }

        guard let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "AudioDownloadManager.restartDownload.write") {
            download.progress = "0"
            download.message = ""
            download.state = .queued
        }
        guard didWrite else { return }

        discardDownload(id: id)
        _ = deleteLocalFile(for: id)
        ProductAnalytics.capture(.downloadStarted(.audio))
        DownloadQueueController.sharedInstance.downloadWasQueued()
    }

    func resumeDownload(id: Int) {
        withActiveDownloadsMap { $0.first(where: { $0.value == id })?.key.resume() }
    }

    func discardDownload(id: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        let task = withActiveDownloadsMap { map -> URLSessionTask? in
            guard let task = map.first(where: { $0.value == id })?.key else { return nil }
            map.removeValue(forKey: task)
            return task
        }
        startTimings.end(id: id, outcome: .cancelled)
        if let task { artifactSaveErrors.removeValue(forKey: task) }
        task?.cancel()
    }

    private func getAbsoluteURL(for relativePath: String) -> URL? {
        DownloadSupport.absoluteDocumentsURL(for: relativePath)
    }

    func getLocalFileLocation(for downloadId: Int) -> DownloadSupport.LocalFileLocation {
        let location = DownloadSupport.localFileLocation(
            from: UserDefaults.standard.object(forKey: String(downloadId)),
            as: String.self,
            resolve: getAbsoluteURL
        )

        switch location {
        case .none:
            log.error("ADM: getLocalFileURL: no filePath found in UserDefaults")
        case .unresolved:
            log.error("ADM: getLocalFileURL: persisted filePath could not be resolved")
        case .resolved(let url):
            log.debug("ADM: getLocalFileURL found: \(url.absoluteString)")
        }
        return location
    }

    func getLocalFileURL(for downloadId: Int) -> URL? {
        guard case .resolved(let url) = getLocalFileLocation(for: downloadId) else {
            return nil
        }
        return url
    }

    @discardableResult
    private func deleteLocalFile(for downloadId: Int) -> DownloadSupport.LocalFileDeletionResult {
        let result = DownloadSupport.deleteLocalFile(
            at: getLocalFileLocation(for: downloadId),
            context: "AudioDownloadManager.deleteLocalFile"
        )
        if result == .removed || result == .alreadyMissing {
            UserDefaults.standard.removeObject(forKey: String(downloadId))
        }
        return result
    }

    static func fileExtension(forMIMEType mimeType: String?) -> String? {
        switch mimeType?.lowercased() {
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/aac", "audio/x-m4a": return "m4a"
        case "audio/flac": return "flac"
        case "audio/wav", "audio/x-wav": return "wav"
        default: return nil
        }
    }

    private func acceptedFileExtension(for task: URLSessionDownloadTask) -> String? {
        guard artifactSaveErrors[task] == nil else { return nil }
        if let error = DownloadSupport.statusError(of: task.response) {
            artifactSaveErrors[task] = error
            return nil
        }
        guard let fileExtension = Self.fileExtension(forMIMEType: task.response?.mimeType) else {
            let error = DownloadSupport.ArtifactSaveError.unsupportedMediaType
            artifactSaveErrors[task] = error
            SentryTelemetry.capture(.unplayableOfflineDownload, error: error)
            return nil
        }
        return fileExtension
    }

    private static func failureMessage(for error: Error) -> String {
        if case .unsupportedMediaType? = error as? DownloadSupport.ArtifactSaveError {
            return NSLocalizedString("This audio format can't be played offline.", comment: "")
        }
        return NSLocalizedString("Download failed. Tap to retry.", comment: "")
    }
}

extension AudioDownloadManager: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = downloadID(for: task, error: error) else { return }
        startTimings.end(id: id, outcome: (artifactSaveErrors[task] ?? error) == nil ? .succeeded : .failed)
        lastProgressUpdateTime.removeValue(forKey: id)
        guard let download = getDownloadFromDatabase(id: id), let realm = download.realm else {
            artifactSaveErrors.removeValue(forKey: task)
            _ = withActiveDownloadsMap { $0.removeValue(forKey: task) }
            DownloadQueueController.sharedInstance.managerDidFinish()
            return
        }

        let artifactError = artifactSaveErrors.removeValue(forKey: task)
        let effectiveError = artifactError ?? error
        let state: Download.State = effectiveError == nil ? .completed : .failed
        let message = effectiveError.map(Self.failureMessage) ?? ""

        let didWrite = DownloadSupport.write(realm, context: "AudioDownloadManager.didComplete.write") {
            download.state = state
            download.message = message
            download.completedAt = state == .completed ? Date() : nil
        }
        guard DownloadSupport.releaseAfterPersistence(didWrite, release: {
            _ = self.withActiveDownloadsMap { $0.removeValue(forKey: task) }
        }) else { return }

        if download.state == .completed {
            notifyUser(for: id)
            ProductAnalytics.capture(.downloadCompleted(.audio))
        } else {
            ProductAnalytics.capture(.downloadFailed(.audio, .init(downloadError: effectiveError)))
        }

        NotificationCenter.default.post(name: VideoDownloadManager.NOTIFICATION, object: nil)
        DownloadQueueController.sharedInstance.managerDidFinish()
    }
}

extension AudioDownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        log.verbose(["ADM: downloadTask-didWriteData task:", downloadTask.taskIdentifier])

        guard let downloadId = withActiveDownloadsMap({ $0[downloadTask] }) else { return }
        guard acceptedFileExtension(for: downloadTask) != nil else {
            startTimings.end(id: downloadId, outcome: .failed)
            downloadTask.cancel()
            return
        }
        startTimings.end(id: downloadId, outcome: .succeeded)
        guard let download = getDownloadFromDatabase(id: downloadId) else { return }

        log.verbose(["ADM: downloadTask-didWriteData download:", downloadId])

        guard totalBytesExpectedToWrite > 0 else { return }

        let currentProgress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
        let oldProgress = (download.progress as NSString).floatValue
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - (lastProgressUpdateTime[downloadId] ?? 0)

        if currentProgress > oldProgress && (oldProgress == 0 || (currentProgress - oldProgress >= 0.02 && elapsed >= 1.0)) {
            log.verbose(["ADM: downloadTask-didWriteData progress:", currentProgress, "oldProgress", oldProgress])
            lastProgressUpdateTime[downloadId] = now

            guard let realm = download.realm else { return }
            _ = DownloadSupport.write(realm, context: "AudioDownloadManager.progress.write") {
                download.progress = String(format: "%.2f", currentProgress)
                if download.state != .active {
                    download.state = .active
                }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        log.verbose(["ADM: downloadTask-didFinishDownloadingTo task:", downloadTask.taskIdentifier])

        guard let id = downloadID(for: downloadTask), let download = getDownloadFromDatabase(id: id) else {
            _ = DownloadSupport.deleteItemIfPresent(
                at: location,
                context: "AudioDownloadManager.didFinishDownloadingTo.unowned"
            )
            return
        }

        guard let fileExtension = acceptedFileExtension(for: downloadTask) else { return }
        let destinationPath = "putio_adm_\(String(download.id))_\(download.name.slugify()).\(fileExtension)"
        if let error = DownloadSupport.saveDownloadedArtifact(
            response: downloadTask.response,
            from: location,
            to: getAbsoluteURL(for: destinationPath)
        ) {
            artifactSaveErrors[downloadTask] = error
            return
        }
        UserDefaults.standard.set(destinationPath, forKey: String(download.id))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        BackgroundDownloadSessionEvents.finish(identifier: identifier)
    }
}
