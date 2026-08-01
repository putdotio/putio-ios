import AVFoundation
import Foundation
import RealmSwift
import UIKit

enum DownloadConcurrencyPreference {
    static let allowedLimits = [1, 2, 3, 4]
    static let defaultLimit = 3
    private static let key = "DownloadConcurrencyPreference.limit"

    static func limit(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: key)
        return allowedLimits.contains(value) ? value : defaultLimit
    }

    static func setLimit(_ value: Int, defaults: UserDefaults = .standard) {
        guard allowedLimits.contains(value) else { return }
        defaults.set(value, forKey: key)
    }
}

protocol DownloadQueueManaging: AnyObject {
    var activeDownloadIDs: Set<Int> { get }
    func beginDownload(id: Int)
    func resumeDownload(id: Int)
    func discardDownload(id: Int)
}

struct DownloadQueueItem: Equatable {
    let id: Int
    let state: Download.State
    let createdAt: Date
}

enum DownloadQueuePolicy {
    static func nextDownloadIDs(
        from items: [DownloadQueueItem],
        occupiedIDs: Set<Int>,
        limit: Int
    ) -> [Int] {
        let availableCount = max(0, limit - occupiedIDs.count)
        return items
            .filter { $0.state == .queued && !occupiedIDs.contains($0.id) }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }
            .prefix(availableCount)
            .map(\.id)
    }

    static func overflowDownloadIDs(
        from items: [DownloadQueueItem],
        activeIDs: Set<Int>,
        limit: Int
    ) -> [Int] {
        items
            .filter { activeIDs.contains($0.id) || $0.state == .starting }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }
            .dropFirst(limit)
            .map(\.id)
    }
}

final class DownloadQueueController {
    static let sharedInstance = DownloadQueueController()

    private var restoredIDsByType = [Download.FileType: Set<Int>]()
    private var tasklessStartIDs = Set<Int>()
    private var hasReconciledRestoredDownloads = false
    private var isEnabled = false

    private init() {}

    func restoreBackgroundSessions() {
        onMain {
            BackgroundDownloadSessionEvents.reconnectLegacySession(
                identifier: DOWNLOAD_LEGACY_BACKGROUND_SESSION_IDENTIFIER
            )
            _ = AudioDownloadManager.sharedInstance
            _ = VideoDownloadManager.sharedInstance
        }
    }

    func start() {
        onMain {
            self.isEnabled = true
            self.restoreBackgroundSessions()
            if self.didRestoreBothManagers {
                self.reconcileRestoredDownloads()
            }
            self.schedule()
        }
    }

    func pause() {
        onMain { self.isEnabled = false }
    }

    func managerDidRestore(_ fileType: Download.FileType, activeIDs: Set<Int>) {
        onMain {
            self.restoredIDsByType[fileType] = activeIDs
            guard self.didRestoreBothManagers, self.isEnabled else { return }
            self.reconcileRestoredDownloads()
            self.schedule()
        }
    }

    func downloadWasQueued() {
        onMain {
            self.restoreBackgroundSessions()
            self.schedule()
        }
    }

    func managerDidFinish() {
        onMain { self.schedule() }
    }

    func startFailed(id: Int) {
        onMain {
            self.tasklessStartIDs.insert(id)
            defer { self.schedule() }
            guard let realm = DownloadSupport.realm(context: "DownloadQueueController.startFailed"),
                  let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return }
            let didWrite = DownloadSupport.write(realm, context: "DownloadQueueController.startFailed.write") {
                download.state = .failed
                download.message = NSLocalizedString("Unable to start download. Tap to retry.", comment: "")
            }
            guard didWrite else { return }
            self.tasklessStartIDs.remove(id)
        }
    }

    func concurrencyLimitDidChange() {
        onMain {
            self.enforceLimit()
            self.schedule()
        }
    }

    private var didRestoreBothManagers: Bool {
        restoredIDsByType[.audio] != nil && restoredIDsByType[.video] != nil
    }

    private func reconcileRestoredDownloads() {
        guard !hasReconciledRestoredDownloads else { return }
        guard let realm = DownloadSupport.realm(context: "DownloadQueueController.restore") else { return }
        let restoredIDs = restoredIDsByType.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        let admittedIDs = Set(
            realm.objects(Download.self)
                .filter { restoredIDs.contains($0.id) && ($0.state == .starting || $0.state == .active) }
                .sorted {
                    if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                    return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
                }
                .prefix(DownloadConcurrencyPreference.limit())
                .map(\.id)
        )

        let didWrite = DownloadSupport.write(realm, context: "DownloadQueueController.restore.write") {
            realm.objects(Download.self).forEach { download in
                guard download.state == .starting || download.state == .active else { return }
                guard !admittedIDs.contains(download.id) else { return }
                download.state = .queued
                download.progress = "0"
                download.message = ""
            }
        }
        guard didWrite else { return }
        hasReconciledRestoredDownloads = true

        restoredIDs.forEach { id in
            let manager: DownloadQueueManaging = restoredIDsByType[.audio]?.contains(id) == true
                ? AudioDownloadManager.sharedInstance
                : VideoDownloadManager.sharedInstance
            if admittedIDs.contains(id) {
                manager.resumeDownload(id: id)
            } else {
                manager.discardDownload(id: id)
            }
        }
    }

    private func enforceLimit() {
        guard isEnabled else { return }
        guard let realm = DownloadSupport.realm(context: "DownloadQueueController.enforceLimit") else { return }

        let audioManager = AudioDownloadManager.sharedInstance
        let videoManager = VideoDownloadManager.sharedInstance
        let audioIDs = audioManager.activeDownloadIDs
        let activeIDs = audioIDs.union(videoManager.activeDownloadIDs)
        let items = realm.objects(Download.self).map {
            DownloadQueueItem(id: $0.id, state: $0.state, createdAt: $0.createdAt ?? .distantPast)
        }
        let overflowIDs = DownloadQueuePolicy.overflowDownloadIDs(
            from: Array(items),
            activeIDs: activeIDs,
            limit: DownloadConcurrencyPreference.limit()
        )
        guard !overflowIDs.isEmpty else { return }

        let didWrite = DownloadSupport.write(realm, context: "DownloadQueueController.enforceLimit.write") {
            overflowIDs.forEach { id in
                guard let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return }
                download.state = .queued
                download.progress = "0"
                download.message = ""
            }
        }
        guard didWrite else { return }

        overflowIDs.forEach { id in
            if audioIDs.contains(id) {
                audioManager.discardDownload(id: id)
            } else {
                videoManager.discardDownload(id: id)
            }
        }
    }

    private func schedule() {
        guard isEnabled, didRestoreBothManagers else { return }
        guard let realm = DownloadSupport.realm(context: "DownloadQueueController.schedule") else { return }

        let audioManager = AudioDownloadManager.sharedInstance
        let videoManager = VideoDownloadManager.sharedInstance
        let taskIDs = audioManager.activeDownloadIDs.union(videoManager.activeDownloadIDs)
        let items = realm.objects(Download.self).map {
            DownloadQueueItem(id: $0.id, state: $0.state, createdAt: $0.createdAt ?? .distantPast)
        }
        let stateIDs = Set(items.compactMap { item in
            (item.state == .starting || item.state == .active) && !self.tasklessStartIDs.contains(item.id)
                ? item.id
                : nil
        })
        let nextIDs = DownloadQueuePolicy.nextDownloadIDs(
            from: Array(items),
            occupiedIDs: taskIDs.union(stateIDs),
            limit: DownloadConcurrencyPreference.limit()
        )
        guard !nextIDs.isEmpty else { return }

        let downloads = nextIDs.compactMap { id -> (Int, Download.FileType)? in
            realm.object(ofType: Download.self, forPrimaryKey: id).map { ($0.id, $0.fileType) }
        }
        let didWrite = DownloadSupport.write(realm, context: "DownloadQueueController.schedule.write") {
            downloads.forEach { id, _ in
                realm.object(ofType: Download.self, forPrimaryKey: id)?.state = .starting
            }
        }
        guard didWrite else { return }

        downloads.forEach { id, type in
            tasklessStartIDs.remove(id)
            switch type {
            case .audio: audioManager.beginDownload(id: id)
            case .video: videoManager.beginDownload(id: id)
            }
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

private final class LegacyDownloadSessionDelegate: NSObject, AVAssetDownloadDelegate {
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        BackgroundDownloadSessionEvents.finish(identifier: identifier)
    }
}

enum BackgroundDownloadSessionEvents {
    private static let lock = NSLock()
    private static var handlers = [String: () -> Void]()
    private static var earlyFinishes = Set<String>()
    private static let legacyDelegate = LegacyDownloadSessionDelegate()
    private static var legacySession: AVAssetDownloadURLSession?

    static func isSupported(_ identifier: String) -> Bool {
        [
            DOWNLOAD_AUDIO_BACKGROUND_SESSION_IDENTIFIER,
            DOWNLOAD_VIDEO_BACKGROUND_SESSION_IDENTIFIER,
            DOWNLOAD_LEGACY_BACKGROUND_SESSION_IDENTIFIER
        ].contains(identifier)
    }

    static func register(identifier: String, completionHandler: @escaping () -> Void) {
        lock.lock()
        let didFinishEarly = earlyFinishes.remove(identifier) != nil
        let replacedHandler = didFinishEarly ? nil : handlers.updateValue(completionHandler, forKey: identifier)
        lock.unlock()
        if didFinishEarly {
            DispatchQueue.main.async(execute: completionHandler)
        } else if let replacedHandler {
            DispatchQueue.main.async(execute: replacedHandler)
        }
    }

    static func finish(
        identifier: String,
        applicationState: UIApplication.State = UIApplication.shared.applicationState
    ) {
        lock.lock()
        let handler = handlers.removeValue(forKey: identifier)
        if handler == nil, applicationState != .active {
            earlyFinishes.insert(identifier)
        }
        lock.unlock()
        if let handler { DispatchQueue.main.async(execute: handler) }
    }

    static func reconnectLegacySession(identifier: String) {
        guard identifier == DOWNLOAD_LEGACY_BACKGROUND_SESSION_IDENTIFIER else { return }
        if legacySession == nil {
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.sessionSendsLaunchEvents = true
            legacySession = AVAssetDownloadURLSession(
                configuration: configuration,
                assetDownloadDelegate: legacyDelegate,
                delegateQueue: .main
            )
        }
        legacySession?.getAllTasks { $0.forEach { $0.cancel() } }
    }
}
