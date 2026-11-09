import AVFoundation
import Foundation
import os
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
    func resumeDownload(id: Int)
    func discardDownload(id: Int)
}

struct DownloadQueueItem: Equatable {
    let id: Int
    let state: Download.State
    let createdAt: Date
}

struct DownloadQueueRestorationPlan: Equatable {
    let admittedIDs: Set<Int>
    let overflowIDs: Set<Int>
}

enum DownloadQueuePolicy {
    static func restorationPlan(
        from items: [DownloadQueueItem],
        restoredIDs: Set<Int>,
        limit: Int
    ) -> DownloadQueueRestorationPlan {
        let activeItems = items.filter { $0.state == .starting || $0.state == .active }
        let restoredItems = fifoSorted(activeItems.filter { restoredIDs.contains($0.id) })
        let admittedIDs = Set(restoredItems.prefix(limit).map(\.id))
        return DownloadQueueRestorationPlan(
            admittedIDs: admittedIDs,
            overflowIDs: Set(activeItems.map(\.id)).subtracting(admittedIDs)
        )
    }

    static func nextDownloadIDs(
        from items: [DownloadQueueItem],
        occupiedIDs: Set<Int>,
        limit: Int
    ) -> [Int] {
        let availableCount = max(0, limit - occupiedIDs.count)
        return fifoSorted(items.filter { $0.state == .queued && !occupiedIDs.contains($0.id) })
            .prefix(availableCount)
            .map(\.id)
    }

    static func overflowDownloadIDs(
        from items: [DownloadQueueItem],
        activeIDs: Set<Int>,
        limit: Int
    ) -> [Int] {
        fifoSorted(items.filter { activeIDs.contains($0.id) || $0.state == .starting })
            .dropFirst(limit)
            .map(\.id)
    }

    private static func fifoSorted(_ items: [DownloadQueueItem]) -> [DownloadQueueItem] {
        items.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
    }
}

final class DownloadQueueController {
    static let sharedInstance = DownloadQueueController()

    private var restoredIDsByType = [Download.FileType: Set<Int>]()
    private var tasklessStartIDs = Set<Int>()
    private var creationsByID = [Int: RecordCreation]()
    private let creationGenerations = OSAllocatedUnfairLock(initialState: CreationGenerations())
    private var hasReconciledRestoredDownloads = false
    private(set) var isEnabled = false
    private var pendingAccountChangeDeletes = 0
    private var startsAfterAccountChange = false
    private let scheduleFileDeletion: (@escaping () -> Void) -> Void
    private let deleteDownloadRecords: (Realm) -> Bool
    private let defaults: UserDefaults
    private static let accountChangeCleanupPendingKey = "DownloadQueueController.accountChangeCleanupPending"

    init(
        scheduleFileDeletion: @escaping (@escaping () -> Void) -> Void = { DownloadSupport.deletionQueue.async(execute: $0) },
        deleteDownloadRecords: @escaping (Realm) -> Bool = { realm in
            DownloadSupport.write(realm, context: "DownloadQueueController.accountChange.write") {
                realm.delete(realm.objects(Download.self))
            }
        },
        defaults: UserDefaults = .standard
    ) {
        self.scheduleFileDeletion = scheduleFileDeletion
        self.deleteDownloadRecords = deleteDownloadRecords
        self.defaults = defaults
        let cleanupPending = defaults.bool(forKey: Self.accountChangeCleanupPendingKey)
        creationGenerations.withLock { $0.isAccountCleanupPending = cleanupPending }
    }

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
            if self.defaults.bool(forKey: Self.accountChangeCleanupPendingKey) {
                guard self.clearAccountDownloads() else { return }
            }
            guard self.pendingAccountChangeDeletes == 0 else {
                self.startsAfterAccountChange = true
                return
            }
            self.isEnabled = true
            self.restoreBackgroundSessions()
            if self.didRestoreBothManagers {
                self.reconcileRestoredDownloads()
            }
            self.schedule()
        }
    }

    func pause() {
        onMain {
            self.isEnabled = false
            self.startsAfterAccountChange = false
            guard self.restoredIDsByType[.video] != nil else { return }
            let pendingIDs = VideoDownloadManager.sharedInstance.pendingStartIDs
            guard !pendingIDs.isEmpty,
                  let realm = DownloadSupport.realm(context: "DownloadQueueController.pause") else { return }
            let didWrite = DownloadSupport.write(realm, context: "DownloadQueueController.pause.write") {
                pendingIDs.forEach { id in
                    guard let download = realm.object(ofType: Download.self, forPrimaryKey: id),
                          download.state == .starting else { return }
                    download.state = .queued
                    download.message = ""
                }
            }
            guard didWrite else { return }
            VideoDownloadManager.sharedInstance.invalidatePendingStarts(ids: pendingIDs)
        }
    }

    func clearDownloadsForAccountChange() {
        onMain {
            self.isEnabled = false
            self.creationGenerations.withLock {
                $0.account += 1
                $0.isAccountCleanupPending = true
            }
            self.defaults.set(true, forKey: Self.accountChangeCleanupPendingKey)
            self.clearAccountDownloads()
        }
    }

    @discardableResult
    private func clearAccountDownloads() -> Bool {
        guard let realm = DownloadSupport.realm(context: "DownloadQueueController.accountChange") else { return false }
        let downloads = Array(realm.objects(Download.self).map { ($0.id, $0.fileType) })
        let locations = downloads.map { id, fileType -> DownloadSupport.LocalFileLocation in
            switch fileType {
            case .audio:
                AudioDownloadManager.sharedInstance.discardDownload(id: id)
                return AudioDownloadManager.sharedInstance.getLocalFileLocation(for: id)
            case .video:
                VideoDownloadManager.sharedInstance.discardDownload(id: id)
                return VideoDownloadManager.sharedInstance.getLocalFileLocation(for: id)
            }
        }
        guard deleteDownloadRecords(realm) else { return false }
        defaults.removeObject(forKey: Self.accountChangeCleanupPendingKey)
        creationGenerations.withLock { $0.isAccountCleanupPending = false }
        downloads.forEach { id, _ in UserDefaults.standard.removeObject(forKey: String(id)) }
        let pendingFiles = locations.map { DownloadSupport.moveAsideForDeletion($0) }
        pendingAccountChangeDeletes += pendingFiles.count
        pendingFiles.forEach { location in
            scheduleFileDeletion {
                let result = DownloadSupport.deleteLocalFile(at: location, context: "DownloadQueueController.accountChange")
                DispatchQueue.main.async {
                    if result == .failed || result == .unresolvedLocation {
                        SentryTelemetry.capture(.downloadedAssetDeletion, context: "DownloadQueueController.accountChange")
                    }
                    self.accountChangeDeleteDidFinish()
                }
            }
        }
        return true
    }

    private func accountChangeDeleteDidFinish() {
        pendingAccountChangeDeletes -= 1
        guard pendingAccountChangeDeletes == 0, startsAfterAccountChange else { return }
        startsAfterAccountChange = false
        start()
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

    func recordCreationWillStart(id: Int) -> RecordCreationToken {
        dispatchPrecondition(condition: .onQueue(.main))
        creationsByID[id, default: RecordCreation()].pending += 1
        return creationGenerations.withLock { $0.token(for: id) }
    }

    func isRecordCreationCurrent(_ token: RecordCreationToken) -> Bool {
        creationGenerations.withLock { !$0.isAccountCleanupPending && $0.token(for: token.id) == token }
    }

    func invalidateRecordCreations(id: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard creationsByID[id] != nil else { return }
        creationGenerations.withLock { $0.byID[id, default: 0] += 1 }
    }

    func recordCreationDidFinish(id: Int, didWrite: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var creation = creationsByID[id] else { return }
        creation.pending -= 1
        creation.didWrite = creation.didWrite || didWrite
        guard creation.pending == 0 else {
            creationsByID[id] = creation
            return
        }
        creationsByID.removeValue(forKey: id)
        creationGenerations.withLock { _ = $0.byID.removeValue(forKey: id) }
        if creation.didWrite {
            downloadWasQueued()
        } else if isInFlightWithoutTask(id: id) {
            startFailed(id: id)
        }
    }

    private func isInFlightWithoutTask(id: Int) -> Bool {
        guard let realm = DownloadSupport.realm(context: "DownloadQueueController.recordCreation"),
              let state = realm.object(ofType: Download.self, forPrimaryKey: id)?.state else { return false }
        return state == .starting || state == .active
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
            ProductAnalytics.capture(.downloadFailed(.init(download.fileType), .unknown))
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
        let plan = DownloadQueuePolicy.restorationPlan(
            from: realm.objects(Download.self).map {
                DownloadQueueItem(id: $0.id, state: $0.state, createdAt: $0.createdAt ?? .distantPast)
            },
            restoredIDs: restoredIDs,
            limit: DownloadConcurrencyPreference.limit()
        )

        let didWrite = DownloadSupport.write(realm, context: "DownloadQueueController.restore.write") {
            realm.objects(Download.self).forEach { download in
                guard plan.overflowIDs.contains(download.id) else { return }
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
            if plan.admittedIDs.contains(id) {
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
        let items = realm.objects(Download.self)
            .filter { self.creationsByID[$0.id] == nil }
            .map { DownloadQueueItem(id: $0.id, state: $0.state, createdAt: $0.createdAt ?? .distantPast) }
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

private struct RecordCreation {
    var pending = 0
    var didWrite = false
}

struct RecordCreationToken: Equatable {
    let id: Int
    let account: Int
    let record: Int
}

private struct CreationGenerations {
    var account = 0
    var isAccountCleanupPending = false
    var byID = [Int: Int]()

    func token(for id: Int) -> RecordCreationToken {
        RecordCreationToken(id: id, account: account, record: byID[id, default: 0])
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

    /// 2.58.0's sessions, renamed since. Their downloads land where nothing reads them.
    static func cancelShipped258Sessions(completion: @escaping () -> Void) {
        let audio = URLSession(configuration: .background(withIdentifier: "com.putio.tvOS.background.url"))
        let video: [URLSession] = ["com.putio.tvOS.background.av", "com.putio.tvOS.background"].map {
            AVAssetDownloadURLSession(configuration: .background(withIdentifier: $0), assetDownloadDelegate: nil, delegateQueue: .main)
        }
        let group = DispatchGroup()
        for session in [audio] + video {
            group.enter()
            session.getAllTasks { tasks in
                log.info("[Downloads] Cancelling \(tasks.count) task(s) left in \(session.configuration.identifier ?? "")")
                session.invalidateAndCancel()
                group.leave()
            }
        }
        group.notify(queue: .main, execute: completion)
    }
}
