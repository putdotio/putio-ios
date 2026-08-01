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
    fileprivate var activeDownloadsMap = [AVAssetDownloadTask: Int]()
    private var startAttempts = [Int: UUID]()
    private let activeDownloadsLock = NSLock()
    fileprivate var willDownloadToURLMap = [AVAssetDownloadTask: URL]()
    fileprivate var lastProgressUpdateTime = [Int: CFAbsoluteTime]()
    fileprivate var didRestore = false

    var activeDownloadCount: Int {
        withActiveDownloadsMap { $0.count }
    }

    var activeDownloadIDs: Set<Int> {
        withActiveDownloadsMap { Set($0.values) }
    }

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
            tasks.forEach { candidate in
                guard let task = candidate as? AVAssetDownloadTask,
                      let description = task.taskDescription,
                      let id = Int(description),
                      task.state == .running || task.state == .suspended,
                      let download = self.getDownloadFromDatabase(id: id),
                      download.state == .starting || download.state == .active,
                      !restoredIDs.contains(id) else {
                    candidate.cancel()
                    return
                }
                if task.state == .running { task.suspend() }
                self.withActiveDownloadsMap { $0[task] = id }
                restoredIDs.insert(id)
            }
            DownloadQueueController.sharedInstance.managerDidRestore(.video, activeIDs: restoredIDs)
        }
    }

    private func notifyUser(for id: Int) {
        log.verbose(["VDM: notifyUser", id])

        guard let download = getDownloadFromDatabase(id: id) else { return }
        DownloadSupport.enqueueCompletedDownloadNotification(for: download.name)
    }

    private func getDownloadFromDatabase(id: Int) -> Download? {
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
        log.verbose(["VDM: beginDownload", id])
        guard let download = getDownloadFromDatabase(id: id), download.state == .starting else { return }
        let attempt = UUID()
        startAttempts[id] = attempt

        getRemoteStreamURL(for: download, completion: { url in
            guard self.startAttempts[id] == attempt else { return }
            self.startAttempts.removeValue(forKey: id)
            guard let currentDownload = self.getDownloadFromDatabase(id: id),
                  currentDownload.state == .starting,
                  let assetDownloadURLSession = self.assetDownloadURLSession,
                  let url else {
                if self.getDownloadFromDatabase(id: id)?.state == .starting {
                    DownloadQueueController.sharedInstance.startFailed(id: id)
                }
                return
            }

            guard let task = assetDownloadURLSession.makeAssetDownloadTask(
                asset: AVURLAsset(url: url),
                assetTitle: currentDownload.name.slugify(),
                assetArtworkData: nil,
                options: nil
            ) else {
                DownloadQueueController.sharedInstance.startFailed(id: id)
                return
            }

            self.withActiveDownloadsMap { $0[task] = id }

            task.taskDescription = String(id)
            task.resume()

            NotificationCenter.default.post(name: VideoDownloadManager.NOTIFICATION, object: nil)
        })
    }

    func createDownload(from file: PutioFile) {
        log.verbose(["VDM: createDownload", file.id])
        guard let download = Download(file: file, url: "") else { return }
        guard let realm = DownloadSupport.realm(context: "VideoDownloadManager.createDownload") else { return }

        let didWrite = DownloadSupport.write(realm, context: "VideoDownloadManager.createDownload.write") {
            realm.add(download, update: .all)
        }
        guard didWrite else { return }

        discardDownload(id: file.id)
        DownloadQueueController.sharedInstance.downloadWasQueued()
    }

    func cancelDownload(id: Int) {
        log.verbose(["VDM: cancelDownload", id])
        guard let download = getDownloadFromDatabase(id: id) else { return }
        guard let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "VideoDownloadManager.cancelDownload.write") {
            download.progress = "0"
            download.state = .stopped
        }
        guard didWrite else { return }

        discardDownload(id: id)
        DownloadQueueController.sharedInstance.managerDidFinish()
    }

    @discardableResult
    func deleteDownload(id: Int) -> Bool {
        log.verbose(["VDM: deleteDownload", id])
        let download = getDownloadFromDatabase(id: id)

        let didDelete = DownloadSupport.performDeletion(
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
        if didDelete {
            discardDownload(id: id)
            DownloadQueueController.sharedInstance.managerDidFinish()
        }
        return didDelete
    }

    @discardableResult
    func removeDownloadRecord(id: Int) -> Bool {
        guard DownloadSupport.deleteRecord(
            id: id,
            context: "VideoDownloadManager.removeDownloadRecord"
        ) else {
            return false
        }

        discardDownload(id: id)
        UserDefaults.standard.removeObject(forKey: String(id))
        DownloadQueueController.sharedInstance.managerDidFinish()
        return true
    }

    private func withActiveDownloadsMap<Result>(
        _ body: (inout [AVAssetDownloadTask: Int]) -> Result
    ) -> Result {
        activeDownloadsLock.lock()
        defer { activeDownloadsLock.unlock() }
        return body(&activeDownloadsMap)
    }

    func restartDownload(id: Int) {
        log.verbose(["VDM: restartDownload", id])
        guard let download = getDownloadFromDatabase(id: id) else { return }

        guard let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "VideoDownloadManager.restartDownload.write") {
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
        startAttempts.removeValue(forKey: id)
        lastProgressUpdateTime.removeValue(forKey: id)
        let task = withActiveDownloadsMap { map -> AVAssetDownloadTask? in
            guard let task = map.first(where: { $0.value == id })?.key else { return nil }
            map.removeValue(forKey: task)
            return task
        }
        if let task, let url = willDownloadToURLMap.removeValue(forKey: task) {
            _ = DownloadSupport.deleteItemIfPresent(
                at: url,
                context: "VideoDownloadManager.discardDownload"
            )
        }
        task?.cancel()
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
    private func deleteLocalFile(for downloadId: Int) -> DownloadSupport.LocalFileDeletionResult {
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

extension VideoDownloadManager: AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        log.verbose(["VDM: assetDownloadTask-didFinishDownloadingTo", location.absoluteString])
        willDownloadToURLMap[assetDownloadTask] = location
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didResolve resolvedMediaSelection: AVMediaSelection) {
        log.verbose(["VDM: assetDownloadTask-did-resolve: ", resolvedMediaSelection])
    }

    // swiftlint:disable:next line_length
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        log.verbose(["VDM: assetDownloadTask-progress task: ", assetDownloadTask.taskIdentifier])

        guard let downloadId = withActiveDownloadsMap({ $0[assetDownloadTask] }) else { return }
        guard let download = getDownloadFromDatabase(id: downloadId) else { return }

        log.verbose(["VDM: assetDownloadTask-progress download: ", downloadId])

        let expectedDuration = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        guard expectedDuration.isFinite, expectedDuration > 0 else { return }
        var currentProgress = 0.0
        for value in loadedTimeRanges {
            let loadedTimeRange: CMTimeRange = value.timeRangeValue
            currentProgress += CMTimeGetSeconds(loadedTimeRange.duration) / expectedDuration
        }
        guard currentProgress.isFinite else { return }
        currentProgress = min(max(currentProgress, 0), 1)

        let oldProgress = (download.progress as NSString).doubleValue
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - (lastProgressUpdateTime[downloadId] ?? 0)

        if currentProgress > oldProgress && (oldProgress == 0 || (currentProgress - oldProgress >= 0.02 && elapsed >= 1.0)) {
            log.verbose(["VDM: assetDownloadTask-progress percent: ", currentProgress, "oldProgress", oldProgress])
            lastProgressUpdateTime[downloadId] = now

            guard let realm = download.realm else { return }
            _ = DownloadSupport.write(realm, context: "VideoDownloadManager.progress.write") {
                download.progress = String(format: "%.2f", currentProgress)
                if download.state != .active {
                    download.state = .active
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        log.verbose("VDM: didCompleteWithError")

        guard let task = task as? AVAssetDownloadTask else { return }
        log.verbose(["VDM: didCompleteWithError task: ", task.taskIdentifier])

        guard let id = withActiveDownloadsMap({ $0[task] }) else { return }
        lastProgressUpdateTime.removeValue(forKey: id)
        log.verbose(["VDM: didCompleteWithError task.id: ", id])

        guard let download = getDownloadFromDatabase(id: id) else { return }
        log.verbose(["VDM: didCompleteWithError download: ", download.id, download.name])

        let downloadURL = willDownloadToURLMap.removeValue(forKey: task)
        var didFail = error != nil
        if error == nil, let downloadURL {
            do {
                UserDefaults.standard.set(try downloadURL.bookmarkData(), forKey: String(download.id))
            } catch {
                _ = DownloadSupport.deleteItemIfPresent(
                    at: downloadURL,
                    context: "VideoDownloadManager.didComplete.bookmarkCleanup"
                )
                didFail = true
            }
        } else if error == nil {
            didFail = true
        } else if let downloadURL {
            _ = DownloadSupport.deleteItemIfPresent(
                at: downloadURL,
                context: "VideoDownloadManager.didComplete.cleanup"
            )
        }

        log.verbose("VDM: didCompleteWithError: writing to realm")
        guard let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "VideoDownloadManager.didComplete.write") {
            download.state = didFail ? .failed : .completed
            download.message = didFail ? NSLocalizedString("Download failed. Tap to retry.", comment: "") : ""
            download.completedAt = didFail ? nil : Date()
        }
        guard didWrite else { return }
        _ = withActiveDownloadsMap { $0.removeValue(forKey: task) }

        if download.state == .completed {
            notifyUser(for: id)
        }
        log.verbose("VDM: didCompleteWithError: posting notification")
        NotificationCenter.default.post(name: VideoDownloadManager.NOTIFICATION, object: nil)
        DownloadQueueController.sharedInstance.managerDidFinish()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        BackgroundDownloadSessionEvents.finish(identifier: identifier)
    }
}
