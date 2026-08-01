import Foundation
import AVFoundation
import PutioSDK
import RealmSwift
import UserNotifications
import NotificationCenter

class VideoDownloadManager: NSObject, DownloadQueueManaging {
    static let sharedInstance = VideoDownloadManager()
    static let NOTIFICATION = Notification.Name("DOWNLOAD_MANAGER_QUEUE_UPDATED")

    fileprivate var assetDownloadURLSession: AVAssetDownloadURLSession?
    fileprivate var activeDownloadsMap = [URLSessionTask: Int]()
    private let activeDownloadsLock = NSLock()
    var willDownloadToURLMap = [AVAssetDownloadTask: URL]()
    var lastProgressUpdateTime = [Int: CFAbsoluteTime]()
    let pendingAttempts = DownloadAttemptRegistry()
    var activeDownloadCount: Int { withActiveDownloadsMap { $0.count } }

    var activeDownloadIDs: Set<Int> { withActiveDownloadsMap { Set($0.values) } }

    override private init() {
        super.init()

        let backgroundConfiguration = URLSessionConfiguration.background(withIdentifier: DOWNLOAD_VIDEO_BACKGROUND_SESSION_IDENTIFIER)
        backgroundConfiguration.sessionSendsLaunchEvents = true

        log.verbose("VDM: init")

        assetDownloadURLSession = AVAssetDownloadURLSession(
            configuration: backgroundConfiguration,
            assetDownloadDelegate: self,
            delegateQueue: .main
        )

        restore()
    }

    private func restore() {
        guard let assetDownloadURLSession = assetDownloadURLSession else { return }

        assetDownloadURLSession.getAllTasks { (tasks) in
            log.verbose("VDM: restore - task count: \(tasks.count)")
            var restoredIDs = Set<Int>()
            var tasksByDownloadID = [Int: [AVAssetDownloadTask]]()

            tasks.forEach { task in
                guard let assetTask = task as? AVAssetDownloadTask,
                      let downloadID = DownloadTaskCompletionIdentity.parsedDownloadID(
                        from: assetTask.taskDescription
                      ) else {
                    log.error("VDM: restore - unknown task: \(task.taskDescription ?? "")")
                    self.trackDraining(task, restoredIDs: &restoredIDs)
                    return
                }
                tasksByDownloadID[downloadID, default: []].append(assetTask)
            }

            tasksByDownloadID.forEach { downloadID, downloadTasks in
                self.restore(
                    downloadTasks,
                    downloadID: downloadID,
                    restoredIDs: &restoredIDs
                )
            }

            DownloadQueueController.sharedInstance.managerDidRestore(.video, activeIDs: restoredIDs)
        }
    }

    private func restore(
        _ tasks: [AVAssetDownloadTask],
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
            fileType: .video
        )
        var didRestorePreferredTask = false

        tasks.forEach { task in
            let isPreferred = !didRestorePreferredTask && task.taskDescription == preferredDescription
            guard isPreferred, let taskDescription = task.taskDescription else {
                trackDraining(task, restoredIDs: &restoredIDs)
                return
            }
            didRestorePreferredTask = true
            let action = DownloadTaskRestorationPolicy.action(for: download.state, isDuplicate: false)
            guard action != .cancelIgnoringCompletion else {
                trackDraining(task, restoredIDs: &restoredIDs)
                return
            }

            DownloadTaskCompletionIdentity.adopt(
                taskDescription: taskDescription,
                downloadID: downloadID,
                fileType: .video
            )
            withActiveDownloadsMap { $0[task] = downloadID }
            restoredIDs.insert(downloadID)
            if action == .cancelPreservingState {
                task.cancel()
            } else {
                task.resume()
            }
        }
    }

    private func trackDraining(_ task: URLSessionTask, restoredIDs: inout Set<Int>) {
        let drainingID = DownloadTaskCompletionIdentity.drainingDownloadID(
            taskIdentifier: task.taskIdentifier,
            fileType: .video
        )
        withActiveDownloadsMap { $0[task] = drainingID }
        restoredIDs.insert(drainingID)
        task.cancel()
    }

    func notifyUser(for id: Int) {
        log.verbose(["VDM: notifyUser", id])

        guard let download = getDownloadFromDatabase(id: id) else { return }
        DownloadSupport.enqueueCompletedDownloadNotification(for: download.name)
    }

    func getDownloadFromDatabase(id: Int) -> Download? {
        log.verbose(["VDM: getDownloadFromDatabase", id])
        guard let realm = DownloadSupport.realm(context: "VideoDownloadManager.getDownloadFromDatabase") else {
            return nil
        }

        return realm.object(ofType: Download.self, forPrimaryKey: id)
    }

    private func getRemoteStreamURL(for download: Download, completion: @escaping (_ url: URL?) -> Void) {
        var url = "\(api.config.baseURL)/files/\(download.id)/hls/media.m3u8?oauth_token=\(api.config.token)"

        api.getSubtitles(fileID: download.id) { result in
            switch result {
            case .failure:
                log.verbose(["VDM: getRemoteStreamURL, subtitle fetch failed", url])
                completion(DownloadSupport.url(from: url, context: "VideoDownloadManager.getRemoteStreamURL.noSubtitles"))

            case .success(let subtitles):
                guard let firstSubtitle = subtitles.first else {
                    log.verbose(["VDM: getRemoteStreamURL, no subtitles", url])
                    return completion(DownloadSupport.url(from: url, context: "VideoDownloadManager.getRemoteStreamURL.firstSubtitle"))
                }

                url = "\(url)&subtitle_key=\(firstSubtitle.key)"
                log.verbose(["VDM: getRemoteStreamURL, with subtitle", url])
                completion(DownloadSupport.url(from: url, context: "VideoDownloadManager.getRemoteStreamURL.withSubtitle"))
            }
        }
    }

    func beginDownload(id: Int) {
        DownloadSupport.preconditionSerializedTransition()
        log.verbose(["VDM: beginDownload", id])
        guard let download = getDownloadFromDatabase(id: id), download.state == .starting else { return }
        let taskDescription = DownloadTaskCompletionIdentity.begin(
            downloadID: id,
            fileType: .video
        )
        let attempt = pendingAttempts.begin(downloadID: id)

        getRemoteStreamURL(for: download, completion: { url in
            dispatchPrecondition(condition: .onQueue(.main))
            guard self.pendingAttempts.isCurrent(attempt, downloadID: id) else { return }
            guard let currentDownload = self.getDownloadFromDatabase(id: id), currentDownload.state == .starting else { return }
            guard let assetDownloadURLSession = self.assetDownloadURLSession, let url else {
                self.failStart(id: id, attempt: attempt)
                return
            }

            guard let task = assetDownloadURLSession.makeAssetDownloadTask(
                asset: AVURLAsset(url: url),
                assetTitle: currentDownload.name.slugify(),
                assetArtworkData: nil,
                options: nil
            ) else {
                self.failStart(id: id, attempt: attempt)
                return
            }

            self.withActiveDownloadsMap { $0[task] = id }

            task.taskDescription = taskDescription
            guard self.getDownloadFromDatabase(id: id)?.state == .starting,
                  DownloadTaskCompletionIdentity.downloadID(
                    mappedID: id,
                    taskDescription: taskDescription,
                    fileType: .video
                  ) == id,
                  self.pendingAttempts.consume(attempt, downloadID: id) else {
                _ = self.withActiveDownloadsMap { $0.removeValue(forKey: task) }
                task.cancel()
                return
            }
            task.resume()

            NotificationCenter.default.post(name: VideoDownloadManager.NOTIFICATION, object: nil)
        })
    }

    private func failStart(id: Int, attempt: DownloadAttemptRegistry.Token) {
        guard pendingAttempts.consume(attempt, downloadID: id) else { return }
        DownloadQueueController.sharedInstance.startFailed(
            id: id,
            message: NSLocalizedString("Unable to start download. Tap to retry.", comment: "")
        )
    }

    func createDownload(from file: PutioFile) {
        log.verbose(["VDM: createDownload", file.id])
        guard let download = Download(file: file, url: "") else { return }
        guard let realm = DownloadSupport.realm(context: "VideoDownloadManager.createDownload") else { return }

        let didWrite = DownloadSupport.write(realm, context: "VideoDownloadManager.createDownload.write") {
            realm.add(download, update: .all)
        }
        guard didWrite else { return }

        DownloadQueueController.sharedInstance.downloadWasQueued()
    }

    func cancelDownload(id: Int) {
        DownloadSupport.preconditionSerializedTransition()
        log.verbose(["VDM: cancelDownload", id])
        pendingAttempts.invalidate(downloadID: id)
        guard let download = getDownloadFromDatabase(id: id) else { return }

        guard let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "VideoDownloadManager.cancelDownload.write") {
            download.progress = "0"
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
        log.verbose(["VDM: deleteDownload", id])
        let download = getDownloadFromDatabase(id: id)

        return DownloadSupport.performDeletion(
            state: download?.state,
            cancelActiveDownload: { self.cancelDownload(id: id) },
            deleteLocalFile: { self.deleteLocalFile(for: id) },
            deleteRecord: {
                DownloadSupport.deleteRecord(
                    id: id,
                    context: "VideoDownloadManager.deleteDownload"
                )
            },
            localFileDeletionDidSucceed: {
                UserDefaults.standard.removeObject(forKey: String(id))
            }
        )
    }

    @discardableResult
    func removeDownloadRecord(id: Int) -> Bool {
        DownloadSupport.preconditionSerializedTransition()
        pendingAttempts.invalidate(downloadID: id)
        if let task = withActiveDownloadsMap({ $0.first(where: { $0.value == id })?.key }) {
            task.cancel()
        }

        guard DownloadSupport.deleteRecord(
            id: id,
            context: "VideoDownloadManager.removeDownloadRecord"
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
        log.verbose(["VDM: restartDownload", id])
        pendingAttempts.invalidate(downloadID: id)
        guard let download = getDownloadFromDatabase(id: id) else { return }

        guard let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "VideoDownloadManager.restartDownload.write") {
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

    private func getLocalFileLocation(for downloadId: Int) -> DownloadSupport.LocalFileLocation {
        log.verbose(["VDM: getLocalFileURL", downloadId])

        let persistedValue = UserDefaults.standard.object(forKey: String(downloadId))
        let location = DownloadSupport.localFileLocation(
            from: persistedValue,
            as: Data.self
        ) { boomarkData in
            var bookmarkDataIsStale = false

            do {
                let url = try URL(
                    resolvingBookmarkData: boomarkData,
                    bookmarkDataIsStale: &bookmarkDataIsStale
                )

                if bookmarkDataIsStale {
                    log.error("VDM: Bookmark data is stale")
                    return nil
                }

                log.debug(["VDM: Bookmark URL is valid!", url.absoluteString])
                return url
            } catch {
                log.error("VDM: Failed to create URL from bookmark with error: \(error)")
                return nil
            }
        }

        if location == .none {
            log.error("VDM: Failed to receive bookmark")
        } else if location == .unresolved, persistedValue != nil {
            log.error("VDM: Persisted bookmark could not be resolved")
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
        log.verbose(["VDM: deleteLocalFile", downloadId])

        let result = DownloadSupport.deleteLocalFile(
            at: getLocalFileLocation(for: downloadId),
            context: "VideoDownloadManager.deleteLocalFile"
        )
        if result == .removed {
            log.verbose(["VDM: local file deleted", downloadId])
        }
        return result
    }
}
