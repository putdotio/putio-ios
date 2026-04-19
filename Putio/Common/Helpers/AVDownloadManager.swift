import Foundation
import AVFoundation
import RealmSwift
import UserNotifications
import Sentry
import NotificationCenter

class DownloadManager: NSObject {
    static let sharedInstance = DownloadManager()
    static let NOTIFICATION = Notification.Name("DOWNLOAD_MANAGER_QUEUE_UPDATED")

    var queue: [Int] = [] {
        didSet {
            NotificationCenter.default.post(name: DownloadManager.NOTIFICATION, object: nil)
        }
    }

    var task: AVAggregateAssetDownloadTask?

    lazy var session: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: DOWNLOAD_LEGACY_BACKGROUND_SESSION_IDENTIFIER)
        configuration.sessionSendsLaunchEvents = true
        configuration.shouldUseExtendedBackgroundIdleMode = true
        return AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: OperationQueue.main)
    }()

    private func realm(context: String) -> Realm? {
        DownloadSupport.realm(context: context)
    }

    func setup() {
        session.getAllTasks { (tasks) in
            tasks.forEach({ (task) in
                guard let realm = self.realm(context: "DownloadManager.setup"),
                      let taskDescription = task.taskDescription,
                      let id = Int(taskDescription) else { return }
                guard let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return }

                log.debug(["DownloadManager.setup restoring task", task.taskIdentifier, download.id])

                if download.state.rawValue < Download.State.active.rawValue {
                    task.resume()
                }
            })
        }
    }

    func persistTask(download: Download) {
        guard let realm = realm(context: "DownloadManager.persistTask") else { return }

        let didWrite = DownloadSupport.write(realm, context: "DownloadManager.persistTask.write") {
            realm.add(download, update: true)
            download.state = .queued
        }
        guard didWrite else { return }

        queue.append(download.id)

        if queue.count == 1 {
            startTask(id: download.id)
        }
    }

    func createTask(file: File) {
        guard let download = Download(file: file),
              let realm = realm(context: "DownloadManager.createTask") else { return }

        let didWrite = DownloadSupport.write(realm, context: "DownloadManager.createTask.write") {
            realm.add(download, update: true)
            download.state = .queued
        }
        guard didWrite else { return }

        queue.append(download.id)

        if queue.count == 1 {
            startTask(id: download.id)
        }
    }

    func deleteTask(id: Int) {
        guard let realm = realm(context: "DownloadManager.deleteTask"),
              let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return }

        switch download.state {
        case .queued, .starting, .active:
            stopTask(id: id)
        case .completed, .failed, .stopped:
            deleteDownloadedAssetFromDisk(for: download)
        }

        _ = DownloadSupport.write(realm, context: "DownloadManager.deleteTask.write") {
            realm.delete(download)
        }
    }

    func stopTask(id: Int) {
        guard let realm = realm(context: "DownloadManager.stopTask") else { return }
        let download = realm.object(ofType: Download.self, forPrimaryKey: id)

        guard download?.state != .active else {
            task?.cancel()
            return
        }

        _ = DownloadSupport.write(realm, context: "DownloadManager.stopTask.write") {
            download?.state = .stopped
        }

        queue = queue.filter {$0 != id}
    }

    func restartTask(id: Int) {
        guard let realm = realm(context: "DownloadManager.restartTask") else { return }
        let download = realm.object(ofType: Download.self, forPrimaryKey: id)

        _ = DownloadSupport.write(realm, context: "DownloadManager.restartTask.write") {
            download?.state = .queued
        }

        queue.append(id)

        if queue.count == 1 {
            startTask(id: id)
        }
    }

    func onTaskCompleted(id: Int) {
        guard let realm = realm(context: "DownloadManager.onTaskCompleted") else { return }
        let download = realm.object(ofType: Download.self, forPrimaryKey: id)

        _ = DownloadSupport.write(realm, context: "DownloadManager.onTaskCompleted.write") {
            download?.state = .completed
            download?.completedAt = Date()
        }

        notifyUser(for: id)
        queue = queue.filter {$0 != id}
        startNextTask()
    }

    func onTaskCancelled(id: Int, error: NSError) {
        guard let realm = realm(context: "DownloadManager.onTaskCancelled") else { return }
        let download = realm.object(ofType: Download.self, forPrimaryKey: id)

        _ = DownloadSupport.write(realm, context: "DownloadManager.onTaskCancelled.write") {
            download?.state = .failed
            download?.message = error.localizedDescription
        }

        deleteDownloadedAssetFromDisk(for: download)
        queue = queue.filter {$0 != id}
        startNextTask()
    }

    func startNextTask() {
        guard let nextDownloadID = queue.first else { return }
        startTask(id: nextDownloadID)
    }

    func startTask(id: Int) {
        guard let realm = realm(context: "DownloadManager.startTask"),
              let download = realm.object(ofType: Download.self, forPrimaryKey: id),
              let url = DownloadSupport.url(from: download.url, context: "DownloadManager.startTask") else { return }

        _ = DownloadSupport.write(realm, context: "DownloadManager.startTask.write") {
            download.state = .starting
            download.progress = "0"
        }

        let urlAsset = AVURLAsset(url: url)

        task = session.aggregateAssetDownloadTask(
            with: urlAsset,
            mediaSelections: [urlAsset.preferredMediaSelection],
            assetTitle: download.name,
            assetArtworkData: nil,
            options: nil
        )

        task?.taskDescription = String(download.id)
        task?.resume()
    }

    func deleteDownloadedAssetFromDisk(for download: Download?) {
        guard let download = download else { return }

        guard let url = DownloadSupport.url(from: download.path, context: "DownloadManager.deleteDownloadedAssetFromDisk") else { return }
        guard DownloadSupport.deleteItemIfPresent(at: url, context: "DownloadManager.deleteDownloadedAssetFromDisk.remove") else {
            SentrySDK.capture(error: NSError(
                domain: "DownloadManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to delete downloaded asset at \(url.path)"]
            ))
            return
        }
    }

    func wipe() {
        guard let realm = realm(context: "DownloadManager.wipe") else { return }
        realm.objects(Download.self).forEach({ (download) in
            self.deleteDownloadedAssetFromDisk(for: download)
        })
    }

    func notifyUser(for id: Int) {
        guard let realm = realm(context: "DownloadManager.notifyUser"),
              let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return }

        DownloadSupport.enqueueCompletedDownloadNotification(for: download.name)
    }
}

extension DownloadManager: AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask, willDownloadTo location: URL) {
        guard let taskDescription = aggregateAssetDownloadTask.taskDescription,
              let id = Int(taskDescription),
              let realm = realm(context: "DownloadManager.willDownloadTo"),
              let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return }

        _ = DownloadSupport.write(realm, context: "DownloadManager.willDownloadTo.write") {
            download.path = location.absoluteString
        }
    }

    // swiftlint:disable:next line_length function_parameter_count
    func urlSession(_ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange, for mediaSelection: AVMediaSelection) {
        guard let taskDescription = aggregateAssetDownloadTask.taskDescription,
              let id = Int(taskDescription),
              let realm = realm(context: "DownloadManager.didLoad"),
              let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return }

        var progressPercent = 0.0

        for value in loadedTimeRanges {
            let loadedTimeRange: CMTimeRange = value.timeRangeValue
            progressPercent += CMTimeGetSeconds(loadedTimeRange.duration) / CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        }

        let progress = String(format: "%.2f", progressPercent)

        guard progress != download.progress else { return }

        _ = DownloadSupport.write(realm, context: "DownloadManager.didLoad.write") {
            download.progress = progress
            download.state = .active
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let taskDescription = task.taskDescription,
              let id = Int(taskDescription) else { return }

        if let error = error as NSError? {
            self.onTaskCancelled(id: id, error: error)
        } else {
            self.onTaskCompleted(id: id)
        }
    }
}
