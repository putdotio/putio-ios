import Foundation
import AVFoundation
import Alamofire
import RealmSwift
import UserNotifications
import Crashlytics
import NotificationCenter

class DownloadManager: NSObject {
    static let sharedInstance = DownloadManager()
    static let NOTIFICATION = Notification.Name("DOWNLOAD_MANAGER_QUEUE_UPDATED")
    let realm = try! Realm()

    var queue: [Int] = [] {
        didSet {
            NotificationCenter.default.post(name: DownloadManager.NOTIFICATION, object: nil)
        }
    }

    var task: AVAggregateAssetDownloadTask?

    lazy var session: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.putio.tvOS.background")
        configuration.sessionSendsLaunchEvents = true
        configuration.shouldUseExtendedBackgroundIdleMode = true
        return AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: OperationQueue.main)
    }()

    func setup() {
        session.getAllTasks { (tasks) in
            tasks.forEach({ (task) in
                let realm = try! Realm()
                let id = Int(task.taskDescription!)
                guard let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return }

                print(task, download)

                if download.state.rawValue < Download.State.active.rawValue {
                    task.resume()
                }
            })
        }
    }

    func persistTask(download: Download) {
        try! realm.write {
            realm.add(download, update: true)
            download.state = .queued
        }

        queue.append(download.id)

        if queue.count == 1 {
            startTask(id: download.id)
        }
    }

    func createTask(file: File) {
        let download = Download(file: file)!

        try! realm.write {
            realm.add(download, update: true)
            download.state = .queued
        }

        queue.append(download.id)

        if queue.count == 1 {
            startTask(id: download.id)
        }
    }

    func deleteTask(id: Int) {
        let download = realm.object(ofType: Download.self, forPrimaryKey: id)!

        switch download.state {
        case .queued, .starting, .active:
            stopTask(id: id)
        case .completed, .failed, .stopped:
            deleteDownloadedAssetFromDisk(for: download)
        }

        try! realm.write {
            realm.delete(download)
        }
    }

    func stopTask(id: Int) {
        let download = realm.object(ofType: Download.self, forPrimaryKey: id)

        guard download?.state != .active else {
            task?.cancel()
            return
        }

        try! realm.write {
            download?.state = .stopped
        }

        queue = queue.filter {$0 != id}
    }

    func restartTask(id: Int) {
        let download = realm.object(ofType: Download.self, forPrimaryKey: id)

        try! realm.write {
            download?.state = .queued
        }

        queue.append(id)

        if queue.count == 1 {
            startTask(id: id)
        }
    }

    func onTaskCompleted(id: Int) {
        let download = realm.object(ofType: Download.self, forPrimaryKey: id)

        try! realm.write {
            download?.state = .completed
            download?.completedAt = Date()
        }

        notifyUser(for: id)
        queue = queue.filter {$0 != id}
        startNextTask()
    }

    func onTaskCancelled(id: Int, error: NSError) {
        let download = realm.object(ofType: Download.self, forPrimaryKey: id)

        try! realm.write {
            download?.state = .failed
            download?.message = error.localizedDescription
        }

        deleteDownloadedAssetFromDisk(for: download)
        queue = queue.filter {$0 != id}
        startNextTask()
    }

    func startNextTask() {
        guard !queue.isEmpty else { return }
        startTask(id: queue.first!)
    }

    func startTask(id: Int) {
        guard let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return }

        try! realm.write {
            download.state = .starting
            download.progress = "0"
        }

        let urlAsset = AVURLAsset(url: URL(string: (download.url))!)

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

        do {
            try FileManager.default.removeItem(at: URL(string: download.path)!)
        } catch {
            Crashlytics.sharedInstance().recordError(error)
        }
    }

    func wipe() {
        realm.objects(Download.self).forEach({ (download) in
            self.deleteDownloadedAssetFromDisk(for: download)
        })
    }

    func notifyUser(for id: Int) {
        let download = realm.object(ofType: Download.self, forPrimaryKey: id)

        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = "Download Completed!"
        notificationContent.body = "\(download!.name) is ready to play."

        let notificationTrigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let notificationRequest = UNNotificationRequest(
            identifier: "com.putio.tvOS.local_notification",
            content: notificationContent,
            trigger: notificationTrigger
        )

        UNUserNotificationCenter.current().add(notificationRequest, withCompletionHandler: nil)
    }
}

extension DownloadManager: AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask, willDownloadTo location: URL) {
        let id = Int(aggregateAssetDownloadTask.taskDescription!)

        guard let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return }

        try! realm.write {
            download.path = location.absoluteString
        }
    }

    // swiftlint:disable:next line_length function_parameter_count
    func urlSession(_ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange, for mediaSelection: AVMediaSelection) {
        let id = Int(aggregateAssetDownloadTask.taskDescription!)

        guard let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return }

        var progressPercent = 0.0

        for value in loadedTimeRanges {
            let loadedTimeRange: CMTimeRange = value.timeRangeValue
            progressPercent += CMTimeGetSeconds(loadedTimeRange.duration) / CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        }

        let progress = String(format: "%.2f", progressPercent)

        guard progress != download.progress else { return }

        try! realm.write {
            download.progress = progress
            download.state = .active
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = Int(task.taskDescription!)!

        if let error = error as NSError? {
            self.onTaskCancelled(id: id, error: error)
        } else {
            self.onTaskCompleted(id: id)
        }
    }
}
