import Foundation
import RealmSwift

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

struct DownloadQueueItem: Equatable {
    let id: Int
    let fileType: Download.FileType
    let state: Download.State
    let createdAt: Date
}

protocol DownloadQueueManaging: AnyObject {
    var activeDownloadIDs: Set<Int> { get }

    func beginDownload(id: Int)
    func requeueDownload(id: Int)
}

enum DownloadQueuePolicy {
    static func downloadIDsToRequeue(
        from items: [DownloadQueueItem],
        limit: Int
    ) -> [Int] {
        items
            .filter { $0.state == .starting || $0.state == .active }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }
            .dropFirst(limit)
            .map(\.id)
    }

    static func nextDownloadIDs(
        from items: [DownloadQueueItem],
        activeIDs: Set<Int>,
        limit: Int
    ) -> [Int] {
        let startingOrActiveIDs = Set(items.compactMap { item in
            item.state == .starting || item.state == .active ? item.id : nil
        })
        let occupiedCount = activeIDs.union(startingOrActiveIDs).count
        let availableCount = max(0, limit - occupiedCount)

        return items
            .filter { $0.state == .queued && !activeIDs.contains($0.id) }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }
            .prefix(availableCount)
            .map(\.id)
    }

    static func restoredState(
        from state: Download.State,
        hasBackgroundTask: Bool
    ) -> Download.State {
        if hasBackgroundTask {
            switch state {
            case .starting, .active:
                return .active
            case .queued, .completed, .failed, .stopped:
                return state
            }
        }

        if state == .starting || state == .active {
            return .queued
        }
        return state
    }
}

final class DownloadQueueController {
    static let sharedInstance = DownloadQueueController()

    private let realmProvider: () -> Realm?
    private let audioManagerProvider: () -> DownloadQueueManaging
    private let videoManagerProvider: () -> DownloadQueueManaging
    private let limitProvider: () -> Int
    private var restoredIDsByType = [Download.FileType: Set<Int>]()
    private var isStarted = false
    private var canStartQueuedDownloads = false

    private convenience init() {
        self.init(
            realmProvider: { DownloadSupport.realm(context: "DownloadQueueController") },
            audioManagerProvider: { AudioDownloadManager.sharedInstance },
            videoManagerProvider: { VideoDownloadManager.sharedInstance },
            limitProvider: { DownloadConcurrencyPreference.limit() }
        )
    }

    init(
        realmProvider: @escaping () -> Realm?,
        audioManagerProvider: @escaping () -> DownloadQueueManaging,
        videoManagerProvider: @escaping () -> DownloadQueueManaging,
        limitProvider: @escaping () -> Int
    ) {
        self.realmProvider = realmProvider
        self.audioManagerProvider = audioManagerProvider
        self.videoManagerProvider = videoManagerProvider
        self.limitProvider = limitProvider
    }

    func start() {
        performOnMain { [self] in
            canStartQueuedDownloads = true
            guard !isStarted else {
                scheduleNow()
                return
            }
            isStarted = true
            _ = audioManagerProvider()
            _ = videoManagerProvider()
        }
    }

    func restoreBackgroundSessions() {
        performOnMain { [self] in
            guard !isStarted else { return }
            isStarted = true
            _ = audioManagerProvider()
            _ = videoManagerProvider()
        }
    }

    func pause() {
        performOnMain { [self] in canStartQueuedDownloads = false }
    }

    func managerDidRestore(_ fileType: Download.FileType, activeIDs: Set<Int>) {
        performOnMain { [self] in
            #if DEBUG
            guard ProcessInfo.processInfo.environment["PUTIO_E2E_MOCK_API"] != "1" else { return }
            #endif
            restoredIDsByType[fileType] = activeIDs
            guard restoredIDsByType.count == Download.FileType.allCases.count else { return }
            reconcileRestoredDownloads()
            scheduleNow()
        }
    }

    func downloadWasQueued() {
        performOnMain { [self] in
            start()
            scheduleNow()
        }
    }

    func managerDidFinish() {
        performOnMain { [self] in scheduleNow() }
    }

    func startFailed(id: Int, message: String) {
        performOnMain { [self] in
            if let realm = realmProvider(),
               let download = realm.object(ofType: Download.self, forPrimaryKey: id) {
                _ = DownloadSupport.write(realm, context: "DownloadQueueController.startFailed.write") {
                    download.state = .failed
                    download.message = message
                }
            }
            scheduleNow()
        }
    }

    func concurrencyLimitDidChange() {
        performOnMain { [self] in scheduleNow() }
    }

    private func reconcileRestoredDownloads() {
        guard let realm = realmProvider() else { return }
        let restoredIDs = restoredIDsByType.values.reduce(into: Set<Int>()) { result, ids in
            result.formUnion(ids)
        }

        _ = DownloadSupport.write(realm, context: "DownloadQueueController.reconcile.write") {
            for download in realm.objects(Download.self) {
                let state = DownloadQueuePolicy.restoredState(
                    from: download.state,
                    hasBackgroundTask: restoredIDs.contains(download.id)
                )
                if state != download.state {
                    download.state = state
                    if state == .queued {
                        download.message = ""
                    }
                }
            }
        }
    }

    private func scheduleNow() {
        guard canStartQueuedDownloads else { return }
        guard restoredIDsByType.count == Download.FileType.allCases.count else { return }
        guard let realm = realmProvider() else { return }

        let downloads = realm.objects(Download.self)
        let items = downloads.map { download in
            DownloadQueueItem(
                id: download.id,
                fileType: download.fileType,
                state: download.state,
                createdAt: download.createdAt ?? .distantPast
            )
        }
        let audioManager = audioManagerProvider()
        let videoManager = videoManagerProvider()
        let activeIDs = audioManager.activeDownloadIDs.union(videoManager.activeDownloadIDs)
        let idsToRequeue = DownloadQueuePolicy.downloadIDsToRequeue(
            from: Array(items),
            limit: limitProvider()
        )
        guard !requeueDownloads(
            ids: idsToRequeue,
            items: Array(items),
            audioManager: audioManager,
            videoManager: videoManager
        ) else { return }
        let nextIDs = DownloadQueuePolicy.nextDownloadIDs(
            from: Array(items),
            activeIDs: activeIDs,
            limit: limitProvider()
        )
        guard !nextIDs.isEmpty else { return }

        let nextDownloads = nextIDs.compactMap { id -> (Int, Download.FileType)? in
            guard let download = realm.object(ofType: Download.self, forPrimaryKey: id) else { return nil }
            return (download.id, download.fileType)
        }

        let didWrite = DownloadSupport.write(realm, context: "DownloadQueueController.schedule.write") {
            nextDownloads.forEach { id, _ in
                realm.object(ofType: Download.self, forPrimaryKey: id)?.state = .starting
            }
        }
        guard didWrite else { return }

        nextDownloads.forEach { id, fileType in
            switch fileType {
            case .audio:
                audioManager.beginDownload(id: id)
            case .video:
                videoManager.beginDownload(id: id)
            }
        }
    }

    private func requeueDownloads(
        ids: [Int],
        items: [DownloadQueueItem],
        audioManager: DownloadQueueManaging,
        videoManager: DownloadQueueManaging
    ) -> Bool {
        guard !ids.isEmpty else { return false }

        ids.forEach { id in
            guard let item = items.first(where: { $0.id == id }) else { return }
            switch item.fileType {
            case .audio:
                audioManager.requeueDownload(id: id)
            case .video:
                videoManager.requeueDownload(id: id)
            }
        }
        DispatchQueue.main.async { [weak self] in self?.scheduleNow() }
        return true
    }

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

extension AudioDownloadManager {
    func requeueDownload(id: Int) {
        DownloadSupport.preconditionSerializedTransition()
        guard let download = getDownloadFromDatabase(id: id), let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "AudioDownloadManager.requeueDownload.write") {
            download.progress = "0"
            download.message = ""
            download.state = .queued
        }
        guard didWrite else { return }

        if let task = withActiveDownloadsMap({ $0.first(where: { $0.value == id })?.key }) {
            task.cancel()
        }
    }
}

extension VideoDownloadManager {
    func requeueDownload(id: Int) {
        DownloadSupport.preconditionSerializedTransition()
        pendingAttempts.invalidate(downloadID: id)
        guard let download = getDownloadFromDatabase(id: id), let realm = download.realm else { return }
        let didWrite = DownloadSupport.write(realm, context: "VideoDownloadManager.requeueDownload.write") {
            download.progress = "0"
            download.message = ""
            download.state = .queued
        }
        guard didWrite else { return }

        if let task = withActiveDownloadsMap({ $0.first(where: { $0.value == id })?.key }) {
            task.cancel()
        }
    }
}

enum BackgroundDownloadSessionEvents {
    private static let lock = NSLock()
    private static var completionHandlers = [String: () -> Void]()

    static func register(identifier: String, completionHandler: @escaping () -> Void) {
        lock.lock()
        completionHandlers[identifier] = completionHandler
        lock.unlock()
    }

    static func finish(identifier: String) {
        lock.lock()
        let completionHandler = completionHandlers.removeValue(forKey: identifier)
        lock.unlock()

        if let completionHandler {
            DispatchQueue.main.async(execute: completionHandler)
        }
    }
}
