import AVFoundation
import Foundation

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
        guard download.state == .starting || download.state == .active else { return }

        log.verbose(["VDM: assetDownloadTask-progress download: ", downloadId])

        let loadedDurations = loadedTimeRanges.map { CMTimeGetSeconds($0.timeRangeValue.duration) }
        guard let currentProgress = DownloadSupport.normalizedProgress(
            loadedDurations: loadedDurations,
            expectedDuration: CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        ) else { return }

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
        DownloadSupport.preconditionSerializedTransition()
        let mappedID = withActiveDownloadsMap { $0.removeValue(forKey: task) }
        guard let task = task as? AVAssetDownloadTask else {
            if mappedID != nil {
                DownloadQueueController.sharedInstance.managerDidFinish()
            }
            return
        }
        guard let id = DownloadTaskCompletionIdentity.downloadID(
            mappedID: mappedID,
            taskDescription: task.taskDescription,
            fileType: .video
        ) else {
            _ = DownloadSupport.deleteItemIfPresent(
                at: willDownloadToURLMap.removeValue(forKey: task),
                context: "VideoDownloadManager.didComplete.stale"
            )
            if mappedID != nil {
                DownloadQueueController.sharedInstance.managerDidFinish()
            }
            return
        }
        defer {
            DownloadTaskCompletionIdentity.clearIfCurrent(
                taskDescription: task.taskDescription,
                downloadID: id,
                fileType: .video
            )
            DownloadQueueController.sharedInstance.managerDidFinish()
        }
        lastProgressUpdateTime.removeValue(forKey: id)
        guard let download = getDownloadFromDatabase(id: id) else {
            _ = DownloadSupport.deleteItemIfPresent(
                at: willDownloadToURLMap.removeValue(forKey: task),
                context: "VideoDownloadManager.didComplete.deleted"
            )
            deleteLocalFile(for: id)
            UserDefaults.standard.removeObject(forKey: String(id))
            return
        }
        let result = completionResult(for: task, download: download, error: error)

        guard let realm = download.realm else { return }
        _ = DownloadSupport.write(realm, context: "VideoDownloadManager.didComplete.write") {
            download.state = result.state
            download.message = result.message
            download.completedAt = DownloadSupport.completedAt(for: result.state)
        }

        if download.state == .completed {
            notifyUser(for: id)
        }

        NotificationCenter.default.post(name: VideoDownloadManager.NOTIFICATION, object: nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        BackgroundDownloadSessionEvents.finish(identifier: identifier)
    }

    private func completionResult(
        for task: AVAssetDownloadTask,
        download: Download,
        error: Error?
    ) -> DownloadSupport.CompletionResult {
        let result = DownloadSupport.completionResult(currentState: download.state, error: error)
        let downloadURL = willDownloadToURLMap.removeValue(forKey: task)
        if result.shouldDiscardArtifact {
            _ = DownloadSupport.deleteItemIfPresent(
                at: downloadURL,
                context: "VideoDownloadManager.didComplete.discard"
            )
            deleteLocalFile(for: download.id)
            UserDefaults.standard.removeObject(forKey: String(download.id))
            return result
        }

        if let error = error as NSError? {
            _ = DownloadSupport.deleteItemIfPresent(
                at: downloadURL,
                context: "VideoDownloadManager.didComplete.error"
            )
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
                deleteLocalFile(for: download.id)
            }
            log.error(["VDM: didCompleteWithError error: ", result.message])
            return result
        }

        guard let downloadURL else {
            return failedArtifactResult()
        }
        do {
            let bookmark = try downloadURL.bookmarkData()
            UserDefaults.standard.set(bookmark, forKey: String(download.id))
            return result
        } catch {
            _ = DownloadSupport.deleteItemIfPresent(
                at: downloadURL,
                context: "VideoDownloadManager.didComplete.bookmark"
            )
            let failedResult = failedArtifactResult()
            log.error(["VDM: didCompleteWithError: ", failedResult.message])
            return failedResult
        }
    }

    private func failedArtifactResult() -> DownloadSupport.CompletionResult {
        DownloadSupport.CompletionResult(
            state: .failed,
            message: NSLocalizedString("Unable to save the downloaded video. Tap to retry.", comment: "")
        )
    }
}
