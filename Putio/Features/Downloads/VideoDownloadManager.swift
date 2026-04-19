import Foundation
import AVFoundation
import PutioSDK
import RealmSwift
import UserNotifications
import NotificationCenter

class VideoDownloadManager: NSObject {
    static let sharedInstance = VideoDownloadManager()
    static let NOTIFICATION = Notification.Name("DOWNLOAD_MANAGER_QUEUE_UPDATED")

    fileprivate var assetDownloadURLSession: AVAssetDownloadURLSession?
    fileprivate var activeDownloadsMap = [AVAssetDownloadTask: Int]()
    fileprivate var willDownloadToURLMap = [AVAssetDownloadTask: URL]()
    fileprivate var lastProgressUpdateTime = [Int: CFAbsoluteTime]()
    fileprivate var didRestore = false

    var activeDownloadCount: Int {
        return activeDownloadsMap.count
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

            tasks.forEach { (t) in
                guard let task = t as? AVAssetDownloadTask, let taskDescription = t.taskDescription else {
                    return log.error("VDM: restore - unknown task: \(t.taskDescription ?? "")")
                }

                guard let downloadId = Int(taskDescription) else {
                    return log.error("VDM: restore - could not cast taskDescription: \(taskDescription)")
                }

                self.activeDownloadsMap[task] = downloadId
                self.cancelDownload(id: downloadId)
            }
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

    private func startDownload(id: Int) {
        log.verbose(["VDM: startDownload", id])
        guard let download = getDownloadFromDatabase(id: id) else { return }

        getRemoteStreamURL(for: download, completion: { url in
            guard let assetDownloadURLSession = self.assetDownloadURLSession else { return }
            guard let url else { return }

            guard let task = assetDownloadURLSession.makeAssetDownloadTask(
                asset: AVURLAsset(url: url),
                assetTitle: download.name.slugify(),
                assetArtworkData: nil,
                options: nil
            ) else { return }

            self.activeDownloadsMap[task] = id

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

        startDownload(id: download.id)
    }

    func cancelDownload(id: Int) {
        log.verbose(["VDM: cancelDownload", id])
        guard let download = getDownloadFromDatabase(id: id) else { return }

        if let activeDownload = activeDownloadsMap.first(where: { $0.value == id }) {
            let task = activeDownload.key
            task.cancel()
        }

        guard let realm = download.realm else { return }
        _ = DownloadSupport.write(realm, context: "VideoDownloadManager.cancelDownload.write") {
            download.progress = "0"
            download.state = .stopped
        }
    }

    func deleteDownload(id: Int) {
        log.verbose(["VDM: deleteDownload", id])
        guard let download = getDownloadFromDatabase(id: id) else { return }

        switch download.state {
        case .queued, .starting, .active:
            cancelDownload(id: id)
        case .completed, .failed, .stopped:
            deleteLocalFile(for: id)
        }

        guard let realm = download.realm else { return }
        _ = DownloadSupport.write(realm, context: "VideoDownloadManager.deleteDownload.write") {
            realm.delete(download)
        }
    }

    func restartDownload(id: Int) {
        log.verbose(["VDM: restartDownload", id])
        guard let download = getDownloadFromDatabase(id: id) else { return }

        cancelDownload(id: id)
        startDownload(id: id)

        guard let realm = download.realm else { return }
        _ = DownloadSupport.write(realm, context: "VideoDownloadManager.restartDownload.write") {
            download.state = .queued
        }
    }

    func getLocalFileURL(for downloadId: Int) -> URL? {
        log.verbose(["VDM: getLocalFileURL", downloadId])

        guard let boomarkData = UserDefaults.standard.value(forKey: String(downloadId)) as? Data else {
            log.error("VDM: Failed to receive bookmark")
            return nil
        }

        var bookmarkDataIsStale = false

        do {
            let url = try URL(resolvingBookmarkData: boomarkData, bookmarkDataIsStale: &bookmarkDataIsStale)

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

    private func deleteLocalFile(for downloadId: Int) {
        log.verbose(["VDM: deleteLocalFile", downloadId])

        guard let url = getLocalFileURL(for: downloadId) else { return }

        guard DownloadSupport.deleteItemIfPresent(at: url, context: "VideoDownloadManager.deleteLocalFile") else { return }
        UserDefaults.standard.removeObject(forKey: String(downloadId))
        log.verbose(["VDM: local file deleted", downloadId])
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

        guard let downloadId = activeDownloadsMap[assetDownloadTask] else { return }
        guard let download = getDownloadFromDatabase(id: downloadId) else { return }

        log.verbose(["VDM: assetDownloadTask-progress download: ", downloadId])

        var currentProgress = 0.0
        for value in loadedTimeRanges {
            let loadedTimeRange: CMTimeRange = value.timeRangeValue
            currentProgress += CMTimeGetSeconds(loadedTimeRange.duration) / CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        }

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

        guard let id = activeDownloadsMap.removeValue(forKey: task) else { return }
        lastProgressUpdateTime.removeValue(forKey: id)
        log.verbose(["VDM: didCompleteWithError task.id: ", id])

        guard let downloadURL = willDownloadToURLMap.removeValue(forKey: task) else { return }
        log.verbose(["VDM: didCompleteWithError downloadURL: ", downloadURL])

        guard let download = getDownloadFromDatabase(id: id) else { return }
        log.verbose(["VDM: didCompleteWithError download: ", download.id, download.name])

        var state = Download.State.completed
        var message = ""

        do {
            log.verbose("VDM: didCompleteWithError: getting boomark data")
            let bookmark = try downloadURL.bookmarkData()
            log.verbose("VDM: didCompleteWithError: saving boomark data to userDefauls")
            UserDefaults.standard.set(bookmark, forKey: String(download.id))
            log.verbose("VDM: didCompleteWithError: bookmark data set")
        } catch {
            state = Download.State.failed
            message = "Unable to decode the bookmark data"
            log.error(["VDM: didCompleteWithError: ", message])
        }

        if let error = error as NSError? {
            switch (error.domain, error.code) {
            case (NSURLErrorDomain, NSURLErrorCancelled):
                deleteLocalFile(for: id)
            default:
                break
            }

            state = Download.State.failed
            message = error.localizedDescription

            log.error(["VDM: didCompleteWithError error: ", message])
        }

        log.verbose("VDM: didCompleteWithError: writing to realm")
        guard let realm = download.realm else { return }
        _ = DownloadSupport.write(realm, context: "VideoDownloadManager.didComplete.write") {
            download.state = state
            download.message = message
            download.completedAt = Date()
        }

        if download.state == .completed {
            notifyUser(for: id)
        }

        log.verbose("VDM: didCompleteWithError: posting notification")
        NotificationCenter.default.post(name: VideoDownloadManager.NOTIFICATION, object: nil)
    }
}
