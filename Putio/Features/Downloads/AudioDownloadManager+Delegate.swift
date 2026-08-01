import Foundation

extension AudioDownloadManager: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DownloadSupport.preconditionSerializedTransition()
        let mappedID = withActiveDownloadsMap { $0.removeValue(forKey: task) }
        let artifactSaveFailed = artifactSaveFailures.remove(task) != nil
        let artifact = downloadedArtifacts.removeValue(forKey: task)
        guard let id = DownloadTaskCompletionIdentity.downloadID(
            mappedID: mappedID,
            taskDescription: task.taskDescription,
            fileType: .audio
        ) else {
            _ = DownloadSupport.deleteItemIfPresent(
                at: artifact?.url,
                context: "AudioDownloadManager.didComplete.stale"
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
                fileType: .audio
            )
            DownloadQueueController.sharedInstance.managerDidFinish()
        }
        lastProgressUpdateTime.removeValue(forKey: id)
        guard let download = getDownloadFromDatabase(id: id) else {
            _ = DownloadSupport.deleteItemIfPresent(
                at: artifact?.url,
                context: "AudioDownloadManager.didComplete.deleted"
            )
            deleteLocalFile(for: id)
            UserDefaults.standard.removeObject(forKey: String(id))
            return
        }

        let result = DownloadSupport.completionResult(
            currentState: download.state,
            error: error,
            artifactSaveFailureMessage: artifactSaveFailed || (error == nil && artifact == nil)
                ? NSLocalizedString("Unable to save the downloaded audio. Tap to retry.", comment: "")
                : nil
        )
        let nsError = error as NSError?
        let wasCancelled = nsError?.code == NSURLErrorCancelled && nsError?.domain == NSURLErrorDomain
        if result.shouldDiscardArtifact || wasCancelled {
            deleteLocalFile(for: id)
        }
        if result.state != .completed {
            _ = DownloadSupport.deleteItemIfPresent(
                at: artifact?.url,
                context: "AudioDownloadManager.didComplete.discard"
            )
        }
        if result.shouldDiscardArtifact {
            UserDefaults.standard.removeObject(forKey: String(id))
        }

        guard let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "AudioDownloadManager.didComplete.write") {
            download.state = result.state
            download.message = result.message
            download.completedAt = DownloadSupport.completedAt(for: result.state)
        }
        guard didWrite else {
            _ = DownloadSupport.deleteItemIfPresent(
                at: artifact?.url,
                context: "AudioDownloadManager.didComplete.writeFailed"
            )
            DownloadQueueController.sharedInstance.startFailed(
                id: id,
                message: result.message.isEmpty
                    ? NSLocalizedString("The download could not be completed. Tap to retry.", comment: "")
                    : result.message
            )
            return
        }

        if download.state == .completed {
            guard let artifact else { return }
            UserDefaults.standard.set(artifact.relativePath, forKey: String(download.id))
            notifyUser(for: id)
        }

        NotificationCenter.default.post(name: VideoDownloadManager.NOTIFICATION, object: nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        BackgroundDownloadSessionEvents.finish(identifier: identifier)
    }
}

extension AudioDownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        log.verbose(["ADM: downloadTask-didWriteData task:", downloadTask.taskIdentifier])

        guard let downloadId = withActiveDownloadsMap({ $0[downloadTask] }) else { return }
        guard let download = getDownloadFromDatabase(id: downloadId) else { return }
        guard download.state == .starting || download.state == .active else { return }

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
        let destinationPath = [
            "putio_adm",
            String(download.id),
            String(downloadTask.taskIdentifier),
            download.name.slugify()
        ].joined(separator: "_") + ".\(fileExtension)"
        guard let destinationURL = getAbsoluteURL(for: destinationPath) else {
            artifactSaveFailures.insert(downloadTask)
            UserDefaults.standard.removeObject(forKey: String(download.id))
            return
        }

        _ = DownloadSupport.deleteItemIfPresent(at: destinationURL, context: "AudioDownloadManager.didFinishDownloadingTo.removeExisting")

        do {
            log.verbose(["ADM: downloadTask-didFinishDownloadingTo saving file to:", destinationURL])
            try FileManager.default.copyItem(at: location, to: destinationURL)
            log.verbose("ADM: downloadTask-didFinishDownloadingTo saved file!")
            artifactSaveFailures.remove(downloadTask)
            downloadedArtifacts[downloadTask] = AudioDownloadManager.DownloadedArtifact(
                url: destinationURL,
                relativePath: destinationPath
            )
        } catch let error {
            artifactSaveFailures.insert(downloadTask)
            UserDefaults.standard.removeObject(forKey: String(download.id))
            log.error(["ADM: downloadTask-didFinishDownloadingTo saved error:", error.localizedDescription])
        }
    }
}
