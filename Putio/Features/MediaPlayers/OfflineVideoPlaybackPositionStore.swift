import Foundation
import RealmSwift

struct OfflineVideoPlaybackPositionUpdate: Codable, Equatable {
    let accountID: Int
    let fileID: Int
    let position: Int
    let expectedRemotePosition: Int
    let lastAttemptedPosition: Int?
    let updatedAt: Date
    let revision: String
}

final class OfflineVideoPlaybackPositionStore {
    static let shared = OfflineVideoPlaybackPositionStore()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let userDefaults: UserDefaults
    private let lock = NSLock()
    private var sessionGeneration: UInt64 = 0
    private static let storageKey = "putio.offline-video-playback-position-updates"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var generation: UInt64 {
        withLock { sessionGeneration }
    }

    func pendingUpdate(for fileID: Int, accountID: Int) -> OfflineVideoPlaybackPositionUpdate? {
        withLock {
            updates().first { $0.accountID == accountID && $0.fileID == fileID }
        }
    }

    func pendingUpdates(accountID: Int) -> [OfflineVideoPlaybackPositionUpdate] {
        withLock {
            updates()
                .filter { $0.accountID == accountID }
                .sorted { $0.updatedAt < $1.updatedAt }
        }
    }

    @discardableResult
    func enqueue(
        accountID: Int,
        fileID: Int,
        position: Int,
        expectedRemotePosition: Int,
        at updatedAt: Date = Date()
    ) -> OfflineVideoPlaybackPositionUpdate {
        withLock {
            var updates = updates()
            let previous = updates.first { $0.accountID == accountID && $0.fileID == fileID }
            let update = OfflineVideoPlaybackPositionUpdate(
                accountID: accountID,
                fileID: fileID,
                position: position,
                expectedRemotePosition: previous?.expectedRemotePosition ?? expectedRemotePosition,
                lastAttemptedPosition: previous?.lastAttemptedPosition,
                updatedAt: updatedAt,
                revision: UUID().uuidString
            )

            updates.removeAll { $0.accountID == accountID && $0.fileID == fileID }
            updates.append(update)
            persist(updates)
            return update
        }
    }

    func restore(_ update: OfflineVideoPlaybackPositionUpdate?, fileID: Int, accountID: Int) {
        withLock {
            var updates = updates()
            updates.removeAll { $0.accountID == accountID && $0.fileID == fileID }
            if let update {
                updates.append(update)
            }
            persist(updates)
        }
    }

    func markUpdateAttempted(_ update: OfflineVideoPlaybackPositionUpdate) {
        replaceIfCurrent(update) { current in
            OfflineVideoPlaybackPositionUpdate(
                accountID: current.accountID,
                fileID: current.fileID,
                position: current.position,
                expectedRemotePosition: current.expectedRemotePosition,
                lastAttemptedPosition: update.position,
                updatedAt: current.updatedAt,
                revision: current.revision
            )
        }
    }

    @discardableResult
    func markRemoteUpdated(_ update: OfflineVideoPlaybackPositionUpdate) -> Bool {
        withLock {
            var updates = updates()
            guard let index = updates.firstIndex(where: {
                $0.accountID == update.accountID && $0.fileID == update.fileID
            }) else { return false }

            if updates[index].revision == update.revision {
                updates.remove(at: index)
                persist(updates)
                return false
            }

            let newer = updates[index]
            updates[index] = OfflineVideoPlaybackPositionUpdate(
                accountID: newer.accountID,
                fileID: newer.fileID,
                position: newer.position,
                expectedRemotePosition: update.position,
                lastAttemptedPosition: nil,
                updatedAt: newer.updatedAt,
                revision: newer.revision
            )
            persist(updates)
            return true
        }
    }

    func rebaseIfCurrent(_ update: OfflineVideoPlaybackPositionUpdate, to remotePosition: Int) {
        replaceIfCurrent(update) { current in
            OfflineVideoPlaybackPositionUpdate(
                accountID: current.accountID,
                fileID: current.fileID,
                position: current.position,
                expectedRemotePosition: remotePosition,
                lastAttemptedPosition: nil,
                updatedAt: current.updatedAt,
                revision: current.revision
            )
        }
    }

    @discardableResult
    func removeIfCurrent(_ update: OfflineVideoPlaybackPositionUpdate) -> Bool {
        withLock {
            var updates = updates()
            guard let index = updates.firstIndex(where: {
                $0.accountID == update.accountID
                    && $0.fileID == update.fileID
                    && $0.revision == update.revision
            }) else { return false }

            updates.remove(at: index)
            persist(updates)
            return true
        }
    }

    func clearAllUpdates() {
        withLock {
            userDefaults.removeObject(forKey: Self.storageKey)
            sessionGeneration &+= 1
        }
    }

    private func updates() -> [OfflineVideoPlaybackPositionUpdate] {
        guard let data = userDefaults.data(forKey: Self.storageKey),
              let updates = try? decoder.decode([OfflineVideoPlaybackPositionUpdate].self, from: data) else {
            return []
        }
        return updates
    }

    private func replaceIfCurrent(
        _ update: OfflineVideoPlaybackPositionUpdate,
        replacement: (OfflineVideoPlaybackPositionUpdate) -> OfflineVideoPlaybackPositionUpdate
    ) {
        withLock {
            var updates = updates()
            guard let index = updates.firstIndex(where: {
                $0.accountID == update.accountID
                    && $0.fileID == update.fileID
                    && $0.revision == update.revision
            }) else { return }

            updates[index] = replacement(updates[index])
            persist(updates)
        }
    }

    private func persist(_ updates: [OfflineVideoPlaybackPositionUpdate]) {
        guard !updates.isEmpty else {
            userDefaults.removeObject(forKey: Self.storageKey)
            return
        }

        guard let data = try? encoder.encode(updates) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

final class OfflineVideoPlaybackPositionPersistence {
    static let shared = OfflineVideoPlaybackPositionPersistence(
        store: .shared,
        requestSync: { OfflineVideoPlaybackPositionSynchronizer.shared.syncPendingUpdates() }
    )

    private let store: OfflineVideoPlaybackPositionStore
    private let requestSync: () -> Void

    init(store: OfflineVideoPlaybackPositionStore, requestSync: @escaping () -> Void) {
        self.store = store
        self.requestSync = requestSync
    }

    @discardableResult
    func save(fileID: Int, position: Int, in realm: Realm) -> Bool {
        guard let accountID = realm.objects(User.self).first?.id,
              let download = realm.object(ofType: Download.self, forPrimaryKey: fileID) else {
            return false
        }

        let previousUpdate = store.pendingUpdate(for: fileID, accountID: accountID)
        store.enqueue(
            accountID: accountID,
            fileID: fileID,
            position: position,
            expectedRemotePosition: previousUpdate?.expectedRemotePosition ?? download.startFrom
        )

        let didWrite = PutioRealm.write(realm, context: "OfflineVideoPlaybackPositionPersistence.save") {
            download.startFrom = position
        }
        guard didWrite else {
            store.restore(previousUpdate, fileID: fileID, accountID: accountID)
            return false
        }

        requestSync()
        return true
    }

    @discardableResult
    func restorePendingLocalPositions(in realm: Realm) -> Bool {
        guard let accountID = realm.objects(User.self).first?.id else { return false }
        let updates = store.pendingUpdates(accountID: accountID)
        guard !updates.isEmpty else { return true }

        return PutioRealm.write(
            realm,
            context: "OfflineVideoPlaybackPositionPersistence.restorePendingLocalPositions"
        ) {
            updates.forEach { update in
                realm.object(ofType: Download.self, forPrimaryKey: update.fileID)?.startFrom = update.position
            }
        }
    }
}
