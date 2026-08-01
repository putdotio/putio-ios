import Foundation
import AVFoundation
import RealmSwift
import UserNotifications
import NotificationCenter
import PutioSDK

class AudioDownloadManager: NSObject, DownloadQueueManaging {
    struct DownloadedArtifact {
        let url: URL
        let relativePath: String
    }

    static let sharedInstance = AudioDownloadManager()
    static let NOTIFICATION = Notification.Name("DOWNLOAD_MANAGER_QUEUE_UPDATED")

    fileprivate var urlSession: URLSession!
    fileprivate var activeDownloadsMap = [URLSessionTask: Int]()
    private let activeDownloadsLock = NSLock()
    var lastProgressUpdateTime = [Int: CFAbsoluteTime]()
    var artifactSaveFailures = Set<URLSessionTask>()
    var downloadedArtifacts = [URLSessionTask: DownloadedArtifact]()

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
            var tasksByDownloadID = [Int: [URLSessionTask]]()

            tasks.forEach { task in
                guard let downloadID = DownloadTaskCompletionIdentity.parsedDownloadID(
                    from: task.taskDescription
                ) else {
                    log.error("ADM: restore - unknown task: \(task.taskDescription ?? "")")
                    self.trackDraining(task, restoredIDs: &restoredIDs)
                    return
                }
                tasksByDownloadID[downloadID, default: []].append(task)
            }

            tasksByDownloadID.forEach { downloadID, downloadTasks in
                self.restore(
                    downloadTasks,
                    downloadID: downloadID,
                    restoredIDs: &restoredIDs
                )
            }

            DownloadQueueController.sharedInstance.managerDidRestore(.audio, activeIDs: restoredIDs)
        }
    }

    private func restore(
        _ tasks: [URLSessionTask],
        downloadID: Int,
        restoredIDs: inout Set<Int>
    ) {
        guard let download = getDownloadFromDatabase(id: downloadID) else {
            tasks.forEach { trackDraining($0, restoredIDs: &restoredIDs) }
            return
        }
        let preferredDescription = DownloadTaskCompletionIdentity.preferredTaskDescription(
            from: tasks.compactMap(\.taskDescription),
            downloadID: downloadID,
            fileType: .audio
        )
        var didRestorePreferredTask = false

        tasks.forEach { task in
            let isPreferred = !didRestorePreferredTask && task.taskDescription == preferredDescription
            guard isPreferred, let taskDescription = task.taskDescription else {
                trackDraining(task, restoredIDs: &restoredIDs)
                return
            }
            didRestorePreferredTask = true
            let action = DownloadTaskRestorationPolicy.action(for: download.state)
            guard action != .cancelIgnoringCompletion else {
                trackDraining(task, restoredIDs: &restoredIDs)
                return
            }

            DownloadTaskCompletionIdentity.adopt(
                taskDescription: taskDescription,
                downloadID: downloadID,
                fileType: .audio
            )
            withActiveDownloadsMap { $0[task] = downloadID }
            restoredIDs.insert(downloadID)
            if action == .cancelPreservingState {
                task.cancel()
            } else if task.state == .running {
                task.suspend()
            }
        }
    }

    private func trackDraining(_ task: URLSessionTask, restoredIDs: inout Set<Int>) {
        let drainingID = DownloadTaskCompletionIdentity.drainingDownloadID(
            taskIdentifier: task.taskIdentifier,
            fileType: .audio
        )
        withActiveDownloadsMap { $0[task] = drainingID }
        restoredIDs.insert(drainingID)
        task.cancel()
    }

    func notifyUser(for id: Int) {
        guard let download = getDownloadFromDatabase(id: id) else { return }
        DownloadSupport.enqueueCompletedDownloadNotification(for: download.name)
    }

    func getDownloadFromDatabase(id: Int) -> Download? {
        guard let realm = DownloadSupport.realm(context: "AudioDownloadManager.getDownloadFromDatabase") else {
            return nil
        }

        return realm.object(ofType: Download.self, forPrimaryKey: id)
    }

    func beginDownload(id: Int) {
        DownloadSupport.preconditionSerializedTransition()
        guard let download = getDownloadFromDatabase(id: id), download.state == .starting else { return }
        guard let url = DownloadSupport.url(from: download.url, context: "AudioDownloadManager.beginDownload") else {
            DownloadQueueController.sharedInstance.startFailed(
                id: id,
                message: NSLocalizedString("Unable to start download. Tap to retry.", comment: "")
            )
            return
        }

        let taskDescription = DownloadTaskCompletionIdentity.begin(
            downloadID: id,
            fileType: .audio
        )
        let task = urlSession.downloadTask(with: url)

        withActiveDownloadsMap { $0[task] = id }

        task.taskDescription = taskDescription
        task.resume()

        NotificationCenter.default.post(name: VideoDownloadManager.NOTIFICATION, object: nil)
    }

    func resumeDownload(id: Int) {
        DownloadSupport.preconditionSerializedTransition()
        guard let task = withActiveDownloadsMap({ $0.first(where: { $0.value == id })?.key }),
              task.state == .suspended else { return }
        task.resume()
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

        DownloadQueueController.sharedInstance.downloadWasQueued()
    }

    func cancelDownload(id: Int) {
        DownloadSupport.preconditionSerializedTransition()
        guard let download = getDownloadFromDatabase(id: id) else { return }

        guard let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "AudioDownloadManager.cancelDownload.write") {
            download.state = .stopped
        }
        guard didWrite else { return }

        if let task = withActiveDownloadsMap({ $0.first(where: { $0.value == id })?.key }) {
            task.cancel()
        }
        DownloadQueueController.sharedInstance.managerDidFinish()
    }

    @discardableResult
    func deleteDownload(id: Int) -> Bool {
        let download = getDownloadFromDatabase(id: id)

        return DownloadSupport.performDeletion(
            state: download?.state,
            cancelActiveDownload: {
                DownloadSupport.performSerializedTransition { self.cancelDownload(id: id) }
            },
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
        DownloadSupport.performSerializedTransition { self.removeDownloadRecordOnMain(id: id) }
    }

    private func removeDownloadRecordOnMain(id: Int) -> Bool {
        DownloadSupport.preconditionSerializedTransition()
        if let task = withActiveDownloadsMap({ $0.first(where: { $0.value == id })?.key }) {
            task.cancel()
        }

        guard DownloadSupport.deleteRecord(
            id: id,
            context: "AudioDownloadManager.removeDownloadRecord"
        ) else {
            return false
        }

        UserDefaults.standard.removeObject(forKey: String(id))
        DownloadQueueController.sharedInstance.managerDidFinish()
        return true
    }

    func withActiveDownloadsMap<Result>(
        _ body: (inout [URLSessionTask: Int]) -> Result
    ) -> Result {
        activeDownloadsLock.lock()
        defer { activeDownloadsLock.unlock() }
        return body(&activeDownloadsMap)
    }

    func restartDownload(id: Int) {
        DownloadSupport.preconditionSerializedTransition()
        log.verbose(["ADM: restartDownload", id])
        guard let download = getDownloadFromDatabase(id: id) else { return }

        guard let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "AudioDownloadManager.restartDownload.write") {
            download.progress = "0"
            download.message = ""
            download.state = .queued
        }
        guard didWrite else { return }

        if let task = withActiveDownloadsMap({ $0.first(where: { $0.value == id })?.key }) {
            task.cancel()
        }
        DownloadQueueController.sharedInstance.downloadWasQueued()
    }

    func getAbsoluteURL(for relativePath: String) -> URL? {
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
    func deleteLocalFile(for downloadId: Int) -> DownloadSupport.LocalFileDeletionResult {
        let result = DownloadSupport.deleteLocalFile(
            at: getLocalFileLocation(for: downloadId),
            context: "AudioDownloadManager.deleteLocalFile"
        )
        return result
    }

    func deriveFileExtensionFromResponse(response: URLResponse?) -> String {
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

extension AudioDownloadManager {
    @discardableResult
    func requeueDownload(id: Int) -> DownloadRequeueResult {
        DownloadSupport.preconditionSerializedTransition()
        guard let download = getDownloadFromDatabase(id: id), let realm = download.realm else { return .failed }
        let didWrite = DownloadSupport.write(realm, context: "AudioDownloadManager.requeueDownload.write") {
            download.progress = "0"
            download.message = ""
            download.state = .queued
        }
        guard didWrite else { return .failed }

        if let task = withActiveDownloadsMap({ $0.first(where: { $0.value == id })?.key }) {
            task.cancel()
            return .awaitingTaskCompletion
        }
        return .completedWithoutTask
    }

    func suspendDownloads() {
        DownloadSupport.preconditionSerializedTransition()
        withActiveDownloadsMap { tasks in
            tasks.keys.filter { $0.state == .running }.forEach { $0.suspend() }
        }
    }
}
