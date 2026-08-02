import Foundation
import PutioSDK
import RealmSwift
import UIKit

private struct OfflineVideoPlaybackSyncPass {
    let accountID: Int
    let generation: UInt64
}

final class OfflineVideoPlaybackPositionSynchronizer {
    typealias FetchRemotePosition = (Int, @escaping (Result<Int, Error>) -> Void) -> Void
    typealias UpdateRemotePosition = (Int, Int, @escaping (Result<Void, Error>) -> Void) -> Void
    typealias ResolveLocalConflict = (Int, Int, Int) -> Bool

    static let shared = OfflineVideoPlaybackPositionSynchronizer(
        store: .shared,
        canAttemptSync: { NetworkReachability.sharedInstance.getIsReachable() },
        currentAccountID: {
            PutioRealm.open(context: "OfflineVideoPlaybackPositionSynchronizer.currentAccount")?
                .objects(User.self).first?.id
        },
        fetchRemotePosition: { fileID, completion in
            api.getStartFrom(fileID: fileID) { result in
                completion(result.mapError { $0 as Error })
            }
        },
        updateRemotePosition: { fileID, position, completion in
            let sdkCompletion: PutioSDKBoolCompletion = { result in
                completion(result.map { _ in () }.mapError { $0 as Error })
            }
            if position == 0 {
                api.resetStartFrom(fileID: fileID, completion: sdkCompletion)
            } else {
                api.setStartFrom(fileID: fileID, time: position, completion: sdkCompletion)
            }
        },
        resolveLocalConflict: { accountID, fileID, remotePosition in
            guard let realm = PutioRealm.open(
                context: "OfflineVideoPlaybackPositionSynchronizer.resolveLocalConflict"
            ), realm.objects(User.self).first?.id == accountID else {
                return false
            }
            guard let download = realm.object(ofType: Download.self, forPrimaryKey: fileID) else {
                return true
            }
            return PutioRealm.write(
                realm,
                context: "OfflineVideoPlaybackPositionSynchronizer.resolveLocalConflict.write"
            ) {
                download.startFrom = remotePosition
            }
        }
    )

    private let store: OfflineVideoPlaybackPositionStore
    private let canAttemptSync: () -> Bool
    private let currentAccountID: () -> Int?
    private let fetchRemotePosition: FetchRemotePosition
    private let updateRemotePosition: UpdateRemotePosition
    private let resolveLocalConflict: ResolveLocalConflict
    private var observerTokens: [NSObjectProtocol] = []
    private var observedNotificationCenter: NotificationCenter?
    private var isSyncing = false
    private var needsAnotherPass = false

    init(
        store: OfflineVideoPlaybackPositionStore,
        canAttemptSync: @escaping () -> Bool = { true },
        currentAccountID: @escaping () -> Int?,
        fetchRemotePosition: @escaping FetchRemotePosition,
        updateRemotePosition: @escaping UpdateRemotePosition,
        resolveLocalConflict: @escaping ResolveLocalConflict = { _, _, _ in true }
    ) {
        self.store = store
        self.canAttemptSync = canAttemptSync
        self.currentAccountID = currentAccountID
        self.fetchRemotePosition = fetchRemotePosition
        self.updateRemotePosition = updateRemotePosition
        self.resolveLocalConflict = resolveLocalConflict
    }

    deinit {
        observerTokens.forEach { observedNotificationCenter?.removeObserver($0) }
    }

    func startObservingReconnects(notificationCenter: NotificationCenter = .default) {
        guard observerTokens.isEmpty else { return }
        observedNotificationCenter = notificationCenter

        observerTokens = [
            NetworkReachability.NOTIFICATION,
            UIApplication.willEnterForegroundNotification
        ].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.syncPendingUpdates()
            }
        }
    }

    func syncPendingUpdates() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.syncPendingUpdates() }
            return
        }
        guard canAttemptSync() else { return }
        guard !isSyncing else {
            needsAnotherPass = true
            return
        }
        guard let accountID = currentAccountID() else { return }

        let generation = store.generation
        let updates = store.pendingUpdates(accountID: accountID)
        guard !updates.isEmpty else { return }

        isSyncing = true
        sync(updates, at: 0, accountID: accountID, generation: generation)
    }

    private func sync(
        _ updates: [OfflineVideoPlaybackPositionUpdate],
        at index: Int,
        accountID: Int,
        generation: UInt64
    ) {
        guard isActive(accountID: accountID, generation: generation), index < updates.count else {
            finishSyncPass()
            return
        }

        let update = updates[index]
        guard isCurrent(update) else {
            sync(updates, at: index + 1, accountID: accountID, generation: generation)
            return
        }

        fetchRemotePosition(update.fileID) { [weak self] result in
            guard let self else { return }
            self.onMain {
                self.handleFetchedPosition(
                    result,
                    update: update,
                    updates: updates,
                    index: index,
                    pass: OfflineVideoPlaybackSyncPass(
                        accountID: accountID,
                        generation: generation
                    )
                )
            }
        }
    }

    private func handleFetchedPosition(
        _ result: Result<Int, Error>,
        update: OfflineVideoPlaybackPositionUpdate,
        updates: [OfflineVideoPlaybackPositionUpdate],
        index: Int,
        pass: OfflineVideoPlaybackSyncPass
    ) {
        guard isActive(accountID: pass.accountID, generation: pass.generation) else {
            finishSyncPass()
            return
        }
        guard case .success(let remotePosition) = result, isCurrent(update) else {
            advance(updates, from: index, accountID: pass.accountID, generation: pass.generation)
            return
        }

        if remotePosition == update.position {
            needsAnotherPass = store.markRemoteUpdated(update) || needsAnotherPass
            advance(updates, from: index, accountID: pass.accountID, generation: pass.generation)
            return
        }

        if remotePosition == update.lastAttemptedPosition {
            store.rebaseIfCurrent(update, to: remotePosition)
            needsAnotherPass = true
            advance(updates, from: index, accountID: pass.accountID, generation: pass.generation)
            return
        }

        guard remotePosition == update.expectedRemotePosition else {
            if resolveLocalConflict(pass.accountID, update.fileID, remotePosition) {
                store.removeIfCurrent(update)
            }
            advance(updates, from: index, accountID: pass.accountID, generation: pass.generation)
            return
        }

        submit(
            update,
            updates: updates,
            index: index,
            accountID: pass.accountID,
            generation: pass.generation
        )
    }

    private func submit(
        _ update: OfflineVideoPlaybackPositionUpdate,
        updates: [OfflineVideoPlaybackPositionUpdate],
        index: Int,
        accountID: Int,
        generation: UInt64
    ) {
        store.markUpdateAttempted(update)
        updateRemotePosition(update.fileID, update.position) { [weak self] result in
            guard let self else { return }
            self.onMain {
                guard self.isActive(accountID: accountID, generation: generation) else {
                    self.finishSyncPass()
                    return
                }
                if case .success = result {
                    self.needsAnotherPass = self.store.markRemoteUpdated(update) || self.needsAnotherPass
                }
                self.advance(updates, from: index, accountID: accountID, generation: generation)
            }
        }
    }

    private func advance(
        _ updates: [OfflineVideoPlaybackPositionUpdate],
        from index: Int,
        accountID: Int,
        generation: UInt64
    ) {
        sync(updates, at: index + 1, accountID: accountID, generation: generation)
    }

    private func isCurrent(_ update: OfflineVideoPlaybackPositionUpdate) -> Bool {
        store.pendingUpdate(for: update.fileID, accountID: update.accountID)?.revision == update.revision
    }

    private func isActive(accountID: Int, generation: UInt64) -> Bool {
        store.generation == generation && currentAccountID() == accountID
    }

    private func onMain(_ operation: @escaping () -> Void) {
        if Thread.isMainThread {
            operation()
        } else {
            DispatchQueue.main.async(execute: operation)
        }
    }

    private func finishSyncPass() {
        isSyncing = false
        guard needsAnotherPass else { return }
        needsAnotherPass = false
        syncPendingUpdates()
    }
}
