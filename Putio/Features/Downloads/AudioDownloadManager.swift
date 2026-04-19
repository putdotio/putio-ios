import Foundation
import AVFoundation
import RealmSwift
import UserNotifications
import NotificationCenter
import PutioSDK

class AudioDownloadManager: NSObject {
    static let sharedInstance = AudioDownloadManager()
    static let NOTIFICATION = Notification.Name("DOWNLOAD_MANAGER_QUEUE_UPDATED")

    fileprivate var urlSession: URLSession!
    fileprivate var activeDownloadsMap = [URLSessionTask: Int]()
    fileprivate var lastProgressUpdateTime = [Int: CFAbsoluteTime]()

    var activeDownloadCount: Int {
        return activeDownloadsMap.count
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

            tasks.forEach { (task) in
                guard let taskDescription = task.taskDescription else {
                    return log.error("ADM: restore - unknown task: \(task.taskDescription ?? "")")
                }

                guard let downloadId = Int(taskDescription) else {
                    return log.error("ADM: restore - could not cast taskDescription: \(taskDescription)")
                }

                self.activeDownloadsMap[task] = downloadId
                self.cancelDownload(id: downloadId)
            }
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

    private func startDownload(id: Int) {
        guard let download = getDownloadFromDatabase(id: id) else { return }
        guard let url = DownloadSupport.url(from: download.url, context: "AudioDownloadManager.startDownload") else { return }

        let task = urlSession.downloadTask(with: url)

        activeDownloadsMap[task] = id

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

        startDownload(id: download.id)
    }

    func cancelDownload(id: Int) {
        guard let download = getDownloadFromDatabase(id: id) else { return }

        if let task = activeDownloadsMap.first(where: { $0.value == id }) {
            task.key.cancel()
        }

        guard let realm = download.realm else { return }
        _ = DownloadSupport.write(realm, context: "AudioDownloadManager.cancelDownload.write") {
            download.state = .stopped
        }
    }

    func deleteDownload(id: Int) {
        guard let download = getDownloadFromDatabase(id: id) else { return }

        switch download.state {
        case .queued, .starting, .active:
            cancelDownload(id: id)
        case .completed, .failed, .stopped:
            deleteLocalFile(for: id)
        }

        guard let realm = download.realm else { return }
        _ = DownloadSupport.write(realm, context: "AudioDownloadManager.deleteDownload.write") {
            realm.delete(download)
        }
    }

    func restartDownload(id: Int) {
        log.verbose(["ADM: restartDownload", id])
        guard let download = getDownloadFromDatabase(id: id) else { return }

        cancelDownload(id: id)
        startDownload(id: id)

        guard let realm = download.realm else { return }
        _ = DownloadSupport.write(realm, context: "AudioDownloadManager.restartDownload.write") {
            download.progress = "0"
            download.state = .queued
        }
    }

    private func getAbsoluteURL(for relativePath: String) -> URL? {
        DownloadSupport.absoluteDocumentsURL(for: relativePath)
    }

    func getLocalFileURL(for downloadId: Int) -> URL? {
        guard let filePath = UserDefaults.standard.value(forKey: String(downloadId)) as? String else {
            log.error("ADM: getLocalFileURL: no filePath found in UserDefaults")
            return nil
        }

        guard let url = getAbsoluteURL(for: filePath) else { return nil }
        log.debug("ADM: getLocalFileURL found: \(url.absoluteString)")
        return url
    }

    private func deleteLocalFile(for downloadId: Int) {
        guard let url = getLocalFileURL(for: downloadId) else { return }

        guard DownloadSupport.deleteItemIfPresent(at: url, context: "AudioDownloadManager.deleteLocalFile") else { return }
        UserDefaults.standard.removeObject(forKey: String(downloadId))
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
        guard let id = activeDownloadsMap.removeValue(forKey: task) else { return }
        lastProgressUpdateTime.removeValue(forKey: id)
        guard let download = getDownloadFromDatabase(id: id) else { return }

        var state = Download.State.completed
        var message = ""

        if let error = error as NSError? {
            switch (error.domain, error.code) {
            case (NSURLErrorDomain, NSURLErrorCancelled):
                deleteLocalFile(for: id)
            default:
                break
            }

            state = Download.State.failed
            message = error.localizedDescription
        }

        guard let realm = download.realm else { return }
        _ = DownloadSupport.write(realm, context: "AudioDownloadManager.didComplete.write") {
            download.state = state
            download.message = message
            download.completedAt = Date()
        }

        if download.state == .completed {
            notifyUser(for: id)
        }

        NotificationCenter.default.post(name: VideoDownloadManager.NOTIFICATION, object: nil)
    }
}

extension AudioDownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        log.verbose(["ADM: downloadTask-didWriteData task:", downloadTask.taskIdentifier])

        guard let downloadId = activeDownloadsMap[downloadTask] else { return }
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

        guard let id = activeDownloadsMap[downloadTask] else { return }
        guard let download = getDownloadFromDatabase(id: id) else { return }

        let fileExtension = deriveFileExtensionFromResponse(response: downloadTask.response)
        let destinationPath = "putio_adm_\(String(download.id))_\(download.name.slugify()).\(fileExtension)"
        guard let destinationURL = getAbsoluteURL(for: destinationPath) else { return }

        _ = DownloadSupport.deleteItemIfPresent(at: destinationURL, context: "AudioDownloadManager.didFinishDownloadingTo.removeExisting")

        do {
            log.verbose(["ADM: downloadTask-didFinishDownloadingTo saving file to:", destinationURL])
            try FileManager.default.copyItem(at: location, to: destinationURL)
            log.verbose("ADM: downloadTask-didFinishDownloadingTo saved file!")
        } catch let error {
            log.error(["ADM: downloadTask-didFinishDownloadingTo saved error:", error.localizedDescription])
        }

        UserDefaults.standard.set(destinationPath, forKey: String(download.id))
    }
}
