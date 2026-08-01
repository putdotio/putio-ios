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

            var restoredIDs = Set<Int>()
            tasks.forEach { task in
                guard let description = task.taskDescription,
                      let id = Int(description),
                      task.state == .running || task.state == .suspended,
                      let download = self.getDownloadFromDatabase(id: id),
                      download.state == .starting || download.state == .active,
                      !restoredIDs.contains(id) else {
                    task.cancel()
                    return
                }
                if task.state == .running { task.suspend() }
                self.withActiveDownloadsMap { $0[task] = id }
                restoredIDs.insert(id)
            }
            DownloadQueueController.sharedInstance.managerDidRestore(.audio, activeIDs: restoredIDs)
        }
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
        guard let download = getDownloadFromDatabase(id: id), download.state == .starting else { return }
        guard let url = DownloadSupport.url(from: download.url, context: "AudioDownloadManager.beginDownload") else {
            DownloadQueueController.sharedInstance.startFailed(id: id)
            return
        }

        let task = urlSession.downloadTask(with: url)

        withActiveDownloadsMap { $0[task] = id }

        task.taskDescription = String(id)
        task.resume()

        NotificationCenter.default.post(name: VideoDownloadManager.NOTIFICATION, object: nil)
    }

    func createDownload(from file: PutioFile) {
        guard file.type == .audio else { return }

        let url = file.getAudioStreamURL(token: api.config.token).absoluteString
        log.debug("ADM: createDownload url: \(url)")

        guard let download = Download(file: file, url: url) else { return }
        guard let realm = DownloadSupport.realm(context: "AudioDownloadManager.createDownload") else { return }

        let didWrite = DownloadSupport.write(realm, context: "AudioDownloadManager.createDownload.write") {
            realm.add(download, update: .all)
        }
        guard didWrite else { return }

        discardDownload(id: file.id)
        DownloadQueueController.sharedInstance.downloadWasQueued()
    }

    func cancelDownload(id: Int) {
        guard let download = getDownloadFromDatabase(id: id) else { return }
        guard let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "AudioDownloadManager.cancelDownload.write") {
            download.progress = "0"
            download.state = .stopped
        }
        guard didWrite else { return }

        discardDownload(id: id)
        _ = deleteLocalFile(for: id)
        DownloadQueueController.sharedInstance.managerDidFinish()
    }

    @discardableResult
    func deleteDownload(id: Int) -> Bool {
        let download = getDownloadFromDatabase(id: id)

        return DownloadSupport.performDeletion(
            state: download?.state,
            cancelActiveDownload: { self.cancelDownload(id: id) },
            deleteLocalFile: { self.deleteLocalFile(for: id) },
            deleteRecord: {
                DownloadSupport.deleteRecord(
                    id: id,
                    context: "AudioDownloadManager.deleteDownload"
                )
            },
            localFileDeletionDidSucceed: {
                UserDefaults.standard.removeObject(forKey: String(id))
            }
        )
    }

    @discardableResult
    func removeDownloadRecord(id: Int) -> Bool {
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
        DownloadQueueController.sharedInstance.downloadWasQueued()
    }

    func resumeDownload(id: Int) {
        withActiveDownloadsMap { $0.first(where: { $0.value == id })?.key.resume() }
    }

    func discardDownload(id: Int) {
        let task = withActiveDownloadsMap { map -> URLSessionTask? in
            guard let task = map.first(where: { $0.value == id })?.key else { return nil }
            map.removeValue(forKey: task)
            return task
        }
        if let task { artifactSaveErrors.removeValue(forKey: task) }
        task?.cancel()
    }

    private func getAbsoluteURL(for relativePath: String) -> URL? {
        DownloadSupport.absoluteDocumentsURL(for: relativePath)
    }

    private func getLocalFileLocation(for downloadId: Int) -> DownloadSupport.LocalFileLocation {
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

    private func deriveFileExtensionFromResponse(response: URLResponse?) -> String {
        var fileExtension = "mp3"

        if let mimeType = response?.mimeType {
            switch mimeType {
            case "audio/mp4":
                fileExtension = "mp4"
            case "audio/x-m4a":
                fileExtension = "m4a"
            case "audio/wav", "audio/wave", "audio/x-wav", "audio/x-pn-wav":
                fileExtension = "wav"
            case "audio/aac", "audio/x-hx-aac-adts":
                fileExtension = "aac"
            case "audio/ogg":
                fileExtension = "ogg"
            case "audio/flac":
                fileExtension = "flac"
            default:
                break
            }
        }

        return fileExtension
    }
}

extension AudioDownloadManager: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = withActiveDownloadsMap({ $0[task] }) else { return }
        lastProgressUpdateTime.removeValue(forKey: id)
        guard let download = getDownloadFromDatabase(id: id) else { return }

        let artifactError = artifactSaveErrors.removeValue(forKey: task)
        let effectiveError = error ?? artifactError
        let state: Download.State = effectiveError == nil ? .completed : .failed
        let message = effectiveError == nil ? "" : NSLocalizedString("Download failed. Tap to retry.", comment: "")

        guard let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "AudioDownloadManager.didComplete.write") {
            download.state = state
            download.message = message
            download.completedAt = state == .completed ? Date() : nil
        }
        guard didWrite else { return }
        _ = withActiveDownloadsMap { $0.removeValue(forKey: task) }

        if download.state == .completed {
            notifyUser(for: id)
        }

        NotificationCenter.default.post(name: VideoDownloadManager.NOTIFICATION, object: nil)
        DownloadQueueController.sharedInstance.managerDidFinish()
    }
}

extension AudioDownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        log.verbose(["ADM: downloadTask-didWriteData task:", downloadTask.taskIdentifier])

        guard let downloadId = withActiveDownloadsMap({ $0[downloadTask] }) else { return }
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

        guard let id = withActiveDownloadsMap({ $0[downloadTask] }) else { return }
        guard let download = getDownloadFromDatabase(id: id) else { return }

        let fileExtension = deriveFileExtensionFromResponse(response: downloadTask.response)
        let destinationPath = "putio_adm_\(String(download.id))_\(download.name.slugify()).\(fileExtension)"
        guard let destinationURL = getAbsoluteURL(for: destinationPath) else { return }

        if let error = DownloadSupport.copyDownloadedArtifact(from: location, to: destinationURL) {
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
