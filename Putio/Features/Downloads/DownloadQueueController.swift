import Foundation
import RealmSwift

extension VideoDownloadManager {
    @discardableResult
    func requeueDownload(id: Int) -> DownloadRequeueResult {
        DownloadSupport.preconditionSerializedTransition()
        pendingAttempts.invalidate(downloadID: id)
        guard let download = getDownloadFromDatabase(id: id), let realm = download.realm else { return .failed }
        let didWrite = DownloadSupport.write(realm, context: "VideoDownloadManager.requeueDownload.write") {
            download.progress = "0"
            download.message = ""
            download.state = .queued
        }
        guard didWrite else { return .failed }
        DownloadTaskCompletionIdentity.clear(downloadID: id, fileType: .video)

        if let task = withActiveDownloadsMap({ $0.first(where: { $0.value == id })?.key }) {
            task.cancel()
            return .awaitingTaskCompletion
        }
        return .completedWithoutTask
    }

    func suspendDownloads() {
        DownloadSupport.preconditionSerializedTransition()
        withActiveDownloadsMap { tasks in
            tasks.keys.filter { $0.state == .running }.forEach { $0.suspend() }
        }
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
    func resumeDownload(id: Int)
    func requeueDownload(id: Int) -> DownloadRequeueResult
    func suspendDownloads()
}

enum DownloadQueuePolicy {
    static func downloadIDsToRequeue(
        from items: [DownloadQueueItem],
        activeIDs: Set<Int>,
        limit: Int
    ) -> [Int] {
        let activeItems = items
            .filter { $0.state == .starting || $0.state == .active }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }

        let drainingCount = activeIDs.filter { $0 < 0 }.count
        let admittedCount = max(0, limit - drainingCount)
        return activeItems
            .dropFirst(admittedCount)
            .map(\.id)
    }

    static func downloadIDsToResume(
        from items: [DownloadQueueItem],
        activeIDs: Set<Int>,
        limit: Int
    ) -> [Int] {
        let activeItems = items
            .filter { $0.state == .starting || $0.state == .active }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }
        let drainingCount = activeIDs.filter { $0 < 0 }.count
        let admittedCount = max(0, limit - drainingCount)
        return activeItems.prefix(admittedCount).map(\.id).filter(activeIDs.contains)
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
    private var isPaused = false
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
            isPaused = false
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

    func restoreBackgroundSession(identifier: String) {
        performOnMain { [self] in
            if identifier == DOWNLOAD_AUDIO_BACKGROUND_SESSION_IDENTIFIER {
                _ = audioManagerProvider()
            } else if identifier == DOWNLOAD_VIDEO_BACKGROUND_SESSION_IDENTIFIER {
                _ = videoManagerProvider()
            }
        }
    }

    func pause() {
        performOnMain { [self] in
            isPaused = true
            canStartQueuedDownloads = false
            let audioManager = audioManagerProvider()
            let videoManager = videoManagerProvider()
            audioManager.suspendDownloads()
            videoManager.suspendDownloads()

            guard restoredIDsByType.count == Download.FileType.allCases.count else { return }
            requeueActiveDownloads(audioManager: audioManager, videoManager: videoManager)
        }
    }

    func managerDidRestore(_ fileType: Download.FileType, activeIDs: Set<Int>) {
        performOnMain { [self] in
            #if DEBUG
            guard ProcessInfo.processInfo.environment["PUTIO_E2E_MOCK_API"] != "1" else { return }
            #endif
            restoredIDsByType[fileType] = activeIDs
            guard restoredIDsByType.count == Download.FileType.allCases.count else { return }
            reconcileRestoredDownloads()
            if isPaused {
                requeueActiveDownloads(
                    audioManager: audioManagerProvider(),
                    videoManager: videoManagerProvider()
                )
                return
            }
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

    private func requeueActiveDownloads(
        audioManager: DownloadQueueManaging,
        videoManager: DownloadQueueManaging
    ) {
        guard let realm = realmProvider() else { return }
        let items = realm.objects(Download.self).map { download in
            DownloadQueueItem(
                id: download.id,
                fileType: download.fileType,
                state: download.state,
                createdAt: download.createdAt ?? .distantPast
            )
        }
        let ids = items
            .filter { $0.state == .starting || $0.state == .active }
            .map(\.id)
        _ = requeueDownloads(
            ids: Array(ids),
            items: Array(items),
            audioManager: audioManager,
            videoManager: videoManager
        )
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
            activeIDs: activeIDs,
            limit: limitProvider()
        )
        guard !requeueDownloads(
            ids: idsToRequeue,
            items: Array(items),
            audioManager: audioManager,
            videoManager: videoManager
        ) else { return }
        let idsToResume = DownloadQueuePolicy.downloadIDsToResume(
            from: Array(items),
            activeIDs: activeIDs,
            limit: limitProvider()
        )
        idsToResume.forEach { id in
            guard let item = items.first(where: { $0.id == id }) else { return }
            manager(for: item.fileType, audio: audioManager, video: videoManager)
                .resumeDownload(id: id)
        }
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
            manager(for: fileType, audio: audioManager, video: videoManager)
                .beginDownload(id: id)
        }
    }

    private func requeueDownloads(
        ids: [Int],
        items: [DownloadQueueItem],
        audioManager: DownloadQueueManaging,
        videoManager: DownloadQueueManaging
    ) -> Bool {
        guard !ids.isEmpty else { return false }

        var didRequeue = false
        var isAwaitingTaskCompletion = false
        ids.forEach { id in
            guard let item = items.first(where: { $0.id == id }) else { return }
            let itemManager = manager(for: item.fileType, audio: audioManager, video: videoManager)
            let result = itemManager.requeueDownload(id: id)
            didRequeue = result.didRequeue || didRequeue
            isAwaitingTaskCompletion = result == .awaitingTaskCompletion || isAwaitingTaskCompletion
        }
        if didRequeue && !isAwaitingTaskCompletion && canStartQueuedDownloads {
            DispatchQueue.main.async { [weak self] in self?.scheduleNow() }
        }
        return didRequeue
    }

    private func manager(
        for fileType: Download.FileType,
        audio: DownloadQueueManaging,
        video: DownloadQueueManaging
    ) -> DownloadQueueManaging {
        fileType == .audio ? audio : video
    }

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
