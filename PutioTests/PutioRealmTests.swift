import XCTest
@testable import Putio
import RealmSwift

final class PutioRealmTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()

        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PutioRealmTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        defaultsSuiteName = "PutioRealmTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)

        defaults = nil
        defaultsSuiteName = nil
        temporaryDirectory = nil

        try super.tearDownWithError()
    }

    func testConfigurationOpensRealmAtRequestedLocation() throws {
        let realmURL = temporaryDirectory.appendingPathComponent("PutioRealmTests.realm")
        let configuration = PutioRealm.configuration(fileURL: realmURL)

        XCTAssertEqual(configuration.schemaVersion, PutioRealm.latestSchemaVersion)
        XCTAssertEqual(configuration.fileURL, realmURL)
        XCTAssertNotNil(PutioRealm.open(context: "PutioRealmTests.testConfigurationOpensRealmAtRequestedLocation", configuration: configuration))
    }

    func testConfigurationWithoutFileURLProducesOpenableDefaultRealmConfiguration() {
        let configuration = PutioRealm.configuration()

        XCTAssertEqual(configuration.schemaVersion, PutioRealm.latestSchemaVersion)
        XCTAssertNotNil(PutioRealm.open(context: "PutioRealmTests.testConfigurationWithoutFileURLProducesOpenableDefaultRealmConfiguration", configuration: configuration))
    }

    func testNeedsDownloadRecoveryFlagCanBeSetAndCleared() {
        XCTAssertFalse(PutioRealm.needsDownloadRecovery(defaults: defaults))

        PutioRealm.setNeedsDownloadRecovery(true, defaults: defaults)
        XCTAssertTrue(PutioRealm.needsDownloadRecovery(defaults: defaults))

        PutioRealm.setNeedsDownloadRecovery(false, defaults: defaults)
        XCTAssertFalse(PutioRealm.needsDownloadRecovery(defaults: defaults))
    }

    func testRecoverDownloadsIfNeededDoesNothingWhenFlagIsFalse() throws {
        let realmURL = temporaryDirectory.appendingPathComponent("NoRecovery.realm")
        let configuration = PutioRealm.configuration(fileURL: realmURL)
        let realm = try XCTUnwrap(PutioRealm.open(context: "PutioRealmTests.testRecoverDownloadsIfNeededDoesNothingWhenFlagIsFalse", configuration: configuration))

        PutioRealm.recoverDownloadsIfNeeded(
            defaults: defaults,
            documentsURL: temporaryDirectory,
            realm: realm,
            shouldEnrichPlaceholders: false
        )

        XCTAssertEqual(realm.objects(Download.self).count, 0)
        XCTAssertFalse(PutioRealm.needsDownloadRecovery(defaults: defaults))
    }

    func testRecoverDownloadsIfNeededRebuildsAudioDownloadsFromDocumentsDirectory() throws {
        let realmURL = temporaryDirectory.appendingPathComponent("RecoveredDownloads.realm")
        let configuration = PutioRealm.configuration(fileURL: realmURL)
        let realm = try XCTUnwrap(PutioRealm.open(context: "PutioRealmTests.testRecoverDownloadsIfNeededRebuildsAudioDownloadsFromDocumentsDirectory", configuration: configuration))

        let recoveredAudioFilename = "putio_adm_123_some-audio.mp3"
        let recoveredAudioURL = temporaryDirectory.appendingPathComponent(recoveredAudioFilename)
        FileManager.default.createFile(atPath: recoveredAudioURL.path, contents: Data("audio".utf8))

        PutioRealm.setNeedsDownloadRecovery(true, defaults: defaults)
        PutioRealm.recoverDownloadsIfNeeded(
            defaults: defaults,
            documentsURL: temporaryDirectory,
            realm: realm,
            shouldEnrichPlaceholders: false
        )

        let recoveredDownload = try XCTUnwrap(realm.object(ofType: Download.self, forPrimaryKey: 123))
        XCTAssertEqual(recoveredDownload.id, 123)
        XCTAssertEqual(recoveredDownload.fileType, .audio)
        XCTAssertEqual(recoveredDownload.state, .completed)
        XCTAssertEqual(recoveredDownload.name, "Recovering...")
        XCTAssertEqual(defaults.string(forKey: "123"), recoveredAudioFilename)
        XCTAssertFalse(PutioRealm.needsDownloadRecovery(defaults: defaults))
    }

    func testRecoveredAudioFileIdParsesLegacyAndNormalAudioFilenames() {
        XCTAssertEqual(PutioRealm.recoveredAudioFileId(from: "putio_adm_123.mp3"), 123)
        XCTAssertEqual(PutioRealm.recoveredAudioFileId(from: "putio_adm_123_some-audio.mp3"), 123)
        XCTAssertNil(PutioRealm.recoveredAudioFileId(from: "putio_adm_not-a-number.mp3"))
        XCTAssertNil(PutioRealm.recoveredAudioFileId(from: "other_123.mp3"))
    }

    func testLegacyDownloadRawValuesPreserveStateAndFileType() {
        let rawValues = PutioRealm.legacyDownloadRawValues(
            state: Download.State.completed.rawValue,
            fileType: Download.FileType.audio.rawValue
        )

        XCTAssertEqual(rawValues.stateRaw, Download.State.completed.rawValue)
        XCTAssertEqual(rawValues.fileTypeRaw, Download.FileType.audio.rawValue)
    }

    func testVideoPlaybackPositionStoreClearsOnlyPlaybackPositionEntries() {
        let store = VideoPlaybackPositionStore(userDefaults: defaults)
        store.saveLocalPosition(for: 42, position: 120)
        defaults.set("keep", forKey: "other-key")

        XCTAssertNotNil(store.entry(for: 42))

        store.clearAllPositions()

        XCTAssertNil(store.entry(for: 42))
        XCTAssertEqual(defaults.string(forKey: "other-key"), "keep")
    }

    func testOfflinePlaybackProgressPersistsLocallyBeforeRequestingSync() throws {
        let realm = try Realm(configuration: Realm.Configuration(inMemoryIdentifier: #function))
        let download = Download()
        download.id = 42
        download.startFrom = 90
        try realm.write {
            realm.add(makeUser(id: 1, username: "offline-user", mail: "offline@put.io"))
            realm.add(download)
        }

        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        var syncRequestCount = 0
        let persistence = OfflineVideoPlaybackPositionPersistence(store: store) {
            syncRequestCount += 1
        }

        XCTAssertTrue(persistence.save(fileID: 42, position: 180, in: realm))
        XCTAssertEqual(realm.object(ofType: Download.self, forPrimaryKey: 42)?.startFrom, 180)
        XCTAssertEqual(store.pendingUpdate(for: 42, accountID: 1)?.position, 180)
        XCTAssertEqual(store.pendingUpdate(for: 42, accountID: 1)?.expectedRemotePosition, 90)
        XCTAssertEqual(syncRequestCount, 1)
    }

    func testOfflinePlaybackSaveRestoresPreviousQueueEntryWhenRealmWriteFails() throws {
        let realm = try Realm(configuration: Realm.Configuration(inMemoryIdentifier: #function))
        let download = Download()
        download.id = 42
        download.startFrom = 90
        try realm.write {
            realm.add(makeUser(id: 1, username: "offline-user", mail: "offline@put.io"))
            realm.add(download)
        }

        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        let previousUpdate = store.enqueue(
            accountID: 1,
            fileID: 42,
            position: 120,
            expectedRemotePosition: 90
        )
        var syncRequestCount = 0
        let persistence = OfflineVideoPlaybackPositionPersistence(
            store: store,
            requestSync: { syncRequestCount += 1 },
            writePosition: { _, _, _ in false }
        )

        XCTAssertFalse(persistence.save(fileID: 42, position: 180, in: realm))
        XCTAssertEqual(store.pendingUpdate(for: 42, accountID: 1), previousUpdate)
        XCTAssertEqual(realm.object(ofType: Download.self, forPrimaryKey: 42)?.startFrom, 90)
        XCTAssertEqual(syncRequestCount, 0)
    }

    func testOfflinePlaybackSaveRemovesNewQueueEntryWhenRealmWriteFails() throws {
        let realm = try Realm(configuration: Realm.Configuration(inMemoryIdentifier: #function))
        let download = Download()
        download.id = 42
        download.startFrom = 90
        try realm.write {
            realm.add(makeUser(id: 1, username: "offline-user", mail: "offline@put.io"))
            realm.add(download)
        }

        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        let persistence = OfflineVideoPlaybackPositionPersistence(
            store: store,
            requestSync: { XCTFail("A failed Realm write must not request synchronization") },
            writePosition: { _, _, _ in false }
        )

        XCTAssertFalse(persistence.save(fileID: 42, position: 180, in: realm))
        XCTAssertNil(store.pendingUpdate(for: 42, accountID: 1))
        XCTAssertEqual(realm.object(ofType: Download.self, forPrimaryKey: 42)?.startFrom, 90)
    }

    func testPendingPlaybackQueueRestoresLocalPositionAfterInterruptedWrite() throws {
        let realm = try Realm(configuration: Realm.Configuration(inMemoryIdentifier: #function))
        let download = Download()
        download.id = 42
        download.startFrom = 90
        try realm.write {
            realm.add(makeUser(id: 1, username: "offline-user", mail: "offline@put.io"))
            realm.add(download)
        }

        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        store.enqueue(accountID: 1, fileID: 42, position: 180, expectedRemotePosition: 90)
        let persistence = OfflineVideoPlaybackPositionPersistence(store: store, requestSync: {})

        XCTAssertTrue(persistence.restorePendingLocalPositions(in: realm))
        XCTAssertEqual(realm.object(ofType: Download.self, forPrimaryKey: 42)?.startFrom, 180)
    }

    func testOfflinePlaybackSyncWaitsForSuccessfulRestoreAndRetriesOnForeground() {
        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        store.enqueue(
            accountID: 1,
            fileID: 42,
            position: 0,
            expectedRemotePosition: 120
        )

        let remotePosition = OfflinePlaybackRemotePosition(value: 120)
        let notificationCenter = NotificationCenter()
        var canRestore = false
        var restoreCallCount = 0
        let synchronizer = makeOfflinePlaybackSynchronizer(
            store: store,
            remotePosition: remotePosition,
            prepareForSync: {
                restoreCallCount += 1
                return canRestore
            }
        )
        synchronizer.startObservingReconnects(notificationCenter: notificationCenter)

        notificationCenter.post(name: NetworkReachability.NOTIFICATION, object: nil)
        XCTAssertEqual(remotePosition.value, 120)
        XCTAssertNotNil(store.pendingUpdate(for: 42, accountID: 1))

        canRestore = true
        notificationCenter.post(name: UIApplication.willEnterForegroundNotification, object: nil)

        XCTAssertEqual(restoreCallCount, 2)
        XCTAssertEqual(remotePosition.value, 0)
        XCTAssertNil(store.pendingUpdate(for: 42, accountID: 1))
    }

    func testOfflinePlaybackSyncDoesNotCrossAccountSessions() {
        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        store.enqueue(
            accountID: 1,
            fileID: 42,
            position: 180,
            expectedRemotePosition: 120
        )

        var accountID = 1
        var fetchCompletions: [(Result<Int, Error>) -> Void] = []
        var appliedPositions: [Int] = []
        let synchronizer = OfflineVideoPlaybackPositionSynchronizer(
            store: store,
            currentAccountID: { accountID },
            fetchRemotePosition: { _, completion in fetchCompletions.append(completion) },
            updateRemotePosition: { _, position, completion in
                appliedPositions.append(position)
                completion(.success(()))
            }
        )

        synchronizer.syncPendingUpdates()
        XCTAssertEqual(fetchCompletions.count, 1)

        store.clearAllUpdates()
        accountID = 2
        store.enqueue(
            accountID: 2,
            fileID: 42,
            position: 300,
            expectedRemotePosition: 120
        )
        synchronizer.syncPendingUpdates()
        fetchCompletions[0](.success(120))

        XCTAssertEqual(fetchCompletions.count, 2)
        XCTAssertEqual(appliedPositions, [])

        fetchCompletions[1](.success(120))
        XCTAssertEqual(appliedPositions, [300])
        XCTAssertNil(store.pendingUpdate(for: 42, accountID: 2))
    }

    func testOfflinePlaybackCompletionResetsRemotePositionOnReconnect() {
        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        store.enqueue(
            accountID: 1,
            fileID: 42,
            position: 0,
            expectedRemotePosition: 120
        )

        let remotePosition = OfflinePlaybackRemotePosition(value: 120)
        var isReachable = false
        let notificationCenter = NotificationCenter()
        let synchronizer = makeOfflinePlaybackSynchronizer(
            store: store,
            remotePosition: remotePosition,
            canAttemptSync: { isReachable }
        )
        synchronizer.startObservingReconnects(notificationCenter: notificationCenter)

        notificationCenter.post(name: NetworkReachability.NOTIFICATION, object: nil)
        XCTAssertEqual(remotePosition.value, 120)
        XCTAssertNotNil(store.pendingUpdate(for: 42, accountID: 1))

        isReachable = true
        notificationCenter.post(name: NetworkReachability.NOTIFICATION, object: nil)

        XCTAssertEqual(remotePosition.value, 0)
        XCTAssertNil(store.pendingUpdate(for: 42, accountID: 1))
    }

    func testOfflinePlaybackSyncDoesNotOverwriteConflictingRemoteProgress() {
        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        store.enqueue(
            accountID: 1,
            fileID: 42,
            position: 0,
            expectedRemotePosition: 120
        )

        var remotePosition = 240
        var updateCallCount = 0
        var resolvedLocalPosition: Int?
        let synchronizer = OfflineVideoPlaybackPositionSynchronizer(
            store: store,
            currentAccountID: { 1 },
            fetchRemotePosition: { _, completion in
                completion(.success(remotePosition))
            },
            updateRemotePosition: { _, position, completion in
                updateCallCount += 1
                remotePosition = position
                completion(.success(()))
            },
            resolveLocalConflict: { _, _, position in
                resolvedLocalPosition = position
                return true
            }
        )

        synchronizer.syncPendingUpdates()

        XCTAssertEqual(remotePosition, 240)
        XCTAssertEqual(updateCallCount, 0)
        XCTAssertNil(store.pendingUpdate(for: 42, accountID: 1))
        XCTAssertEqual(resolvedLocalPosition, 240)

        store.enqueue(
            accountID: 1,
            fileID: 42,
            position: 300,
            expectedRemotePosition: 240
        )
        XCTAssertEqual(store.pendingUpdate(for: 42, accountID: 1)?.expectedRemotePosition, 240)
    }

    func testOfflinePlaybackConflictRemainsRetryableWhenLocalResolutionFails() {
        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        store.enqueue(
            accountID: 1,
            fileID: 42,
            position: 0,
            expectedRemotePosition: 120
        )

        let synchronizer = OfflineVideoPlaybackPositionSynchronizer(
            store: store,
            currentAccountID: { 1 },
            fetchRemotePosition: { _, completion in completion(.success(240)) },
            updateRemotePosition: { _, _, _ in XCTFail("A conflict must not update the remote position") },
            resolveLocalConflict: { _, _, _ in false }
        )

        synchronizer.syncPendingUpdates()

        XCTAssertNotNil(store.pendingUpdate(for: 42, accountID: 1))
    }

    func testFailedOfflinePlaybackSyncRemainsRetryable() {
        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        store.enqueue(
            accountID: 1,
            fileID: 42,
            position: 0,
            expectedRemotePosition: 120
        )

        var remotePosition = 120
        var shouldFailUpdate = true
        let synchronizer = OfflineVideoPlaybackPositionSynchronizer(
            store: store,
            currentAccountID: { 1 },
            fetchRemotePosition: { _, completion in
                completion(.success(remotePosition))
            },
            updateRemotePosition: { _, position, completion in
                if shouldFailUpdate {
                    completion(.failure(OfflinePlaybackSyncTestError.unavailable))
                } else {
                    remotePosition = position
                    completion(.success(()))
                }
            }
        )

        synchronizer.syncPendingUpdates()
        XCTAssertNotNil(store.pendingUpdate(for: 42, accountID: 1))
        XCTAssertEqual(remotePosition, 120)

        shouldFailUpdate = false
        synchronizer.syncPendingUpdates()

        XCTAssertEqual(remotePosition, 0)
        XCTAssertNil(store.pendingUpdate(for: 42, accountID: 1))
    }

    func testAmbiguousUpdateFailureReconcilesBeforeSendingNewerProgress() {
        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        store.enqueue(
            accountID: 1,
            fileID: 42,
            position: 180,
            expectedRemotePosition: 120
        )

        var remotePosition = 120
        var firstCompletion: ((Result<Void, Error>) -> Void)?
        var appliedPositions: [Int] = []
        let synchronizer = OfflineVideoPlaybackPositionSynchronizer(
            store: store,
            currentAccountID: { 1 },
            fetchRemotePosition: { _, completion in
                completion(.success(remotePosition))
            },
            updateRemotePosition: { _, position, completion in
                appliedPositions.append(position)
                if firstCompletion == nil {
                    firstCompletion = completion
                } else {
                    remotePosition = position
                    completion(.success(()))
                }
            }
        )

        synchronizer.syncPendingUpdates()
        remotePosition = 180
        store.enqueue(accountID: 1, fileID: 42, position: 200, expectedRemotePosition: 180)
        synchronizer.syncPendingUpdates()
        firstCompletion?(.failure(OfflinePlaybackSyncTestError.unavailable))

        XCTAssertEqual(appliedPositions, [180, 200])
        XCTAssertEqual(remotePosition, 200)
        XCTAssertNil(store.pendingUpdate(for: 42, accountID: 1))
    }

    func testDeletingDownloadDoesNotDiscardPendingPlaybackUpdate() throws {
        let realm = try Realm(configuration: Realm.Configuration(inMemoryIdentifier: #function))
        let download = Download()
        download.id = 42
        download.startFrom = 120
        try realm.write {
            realm.add(makeUser(id: 1, username: "offline-user", mail: "offline@put.io"))
            realm.add(download)
        }

        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        let persistence = OfflineVideoPlaybackPositionPersistence(store: store, requestSync: {})
        XCTAssertTrue(persistence.save(fileID: 42, position: 0, in: realm))

        try realm.write { realm.delete(realm.objects(Download.self)) }
        XCTAssertNotNil(store.pendingUpdate(for: 42, accountID: 1))

        let remotePosition = OfflinePlaybackRemotePosition(value: 120)
        let synchronizer = makeOfflinePlaybackSynchronizer(store: store, remotePosition: remotePosition)
        synchronizer.syncPendingUpdates()

        XCTAssertEqual(remotePosition.value, 0)
        XCTAssertNil(store.pendingUpdate(for: 42, accountID: 1))
    }

    func testReplaceUserSessionPersistsSingletonUserAndConfig() throws {
        let realmURL = temporaryDirectory.appendingPathComponent("UserSession.realm")
        let configuration = PutioRealm.configuration(fileURL: realmURL)
        let realm = try XCTUnwrap(PutioRealm.open(context: "PutioRealmTests.testReplaceUserSessionPersistsSingletonUserAndConfig", configuration: configuration))

        let didPersist = PutioRealm.replaceUserSession(
            realm,
            user: makeUser(id: 1, username: "putio-ui", mail: "ui@put.io"),
            config: makeConfig(chromecastPlaybackType: "hls"),
            context: "PutioRealmTests.testReplaceUserSessionPersistsSingletonUserAndConfig"
        )

        XCTAssertTrue(didPersist)
        XCTAssertEqual(realm.objects(User.self).count, 1)
        XCTAssertEqual(realm.objects(UserConfig.self).count, 1)
        XCTAssertEqual(realm.objects(User.self).first?.username, "putio-ui")
        XCTAssertEqual(realm.objects(UserConfig.self).first?.chromecastPlaybackType, "hls")
    }

    func testReplaceUserSessionReplacesExistingUserAndConfigWithoutDuplicatingSingletonConfig() throws {
        let realmURL = temporaryDirectory.appendingPathComponent("ReplaceUserSession.realm")
        let configuration = PutioRealm.configuration(fileURL: realmURL)
        let realm = try XCTUnwrap(PutioRealm.open(context: "PutioRealmTests.testReplaceUserSessionReplacesExistingUserAndConfigWithoutDuplicatingSingletonConfig", configuration: configuration))

        XCTAssertTrue(
            PutioRealm.replaceUserSession(
                realm,
                user: makeUser(id: 1, username: "old-user", mail: "old@put.io"),
                config: makeConfig(chromecastPlaybackType: "hls"),
                context: "PutioRealmTests.testReplaceUserSessionReplacesExistingUserAndConfigWithoutDuplicatingSingletonConfig.firstPersist"
            )
        )

        XCTAssertTrue(
            PutioRealm.replaceUserSession(
                realm,
                user: makeUser(id: 1, username: "new-user", mail: "new@put.io"),
                config: makeConfig(chromecastPlaybackType: "mp4"),
                context: "PutioRealmTests.testReplaceUserSessionReplacesExistingUserAndConfigWithoutDuplicatingSingletonConfig.secondPersist"
            )
        )

        XCTAssertEqual(realm.objects(User.self).count, 1)
        XCTAssertEqual(realm.objects(UserConfig.self).count, 1)
        XCTAssertEqual(realm.objects(User.self).first?.username, "new-user")
        XCTAssertEqual(realm.objects(UserConfig.self).first?.chromecastPlaybackType, "mp4")
    }

    private func makeUser(id: Int, username: String, mail: String) -> User {
        let user = User()
        user.id = id
        user.username = username
        user.mail = mail
        user.downloadToken = "download-token-\(id)"
        user.trashSize = 0

        let disk = UserDisk()
        disk.available = 100
        disk.size = 200
        disk.used = 100
        user.disk = disk

        let settings = UserSettings()
        settings.routeName = "default"
        settings.sortBy = "DATE_DESC"
        settings.historyEnabled = true
        settings.trashEnabled = true
        user.settings = settings

        return user
    }

    private func makeConfig(chromecastPlaybackType: String) -> UserConfig {
        let config = UserConfig()
        config.chromecastPlaybackType = chromecastPlaybackType
        return config
    }

    private func makeOfflinePlaybackSynchronizer(
        store: OfflineVideoPlaybackPositionStore,
        remotePosition: OfflinePlaybackRemotePosition,
        prepareForSync: @escaping () -> Bool = { true },
        canAttemptSync: @escaping () -> Bool = { true }
    ) -> OfflineVideoPlaybackPositionSynchronizer {
        return OfflineVideoPlaybackPositionSynchronizer(
            store: store,
            prepareForSync: prepareForSync,
            canAttemptSync: canAttemptSync,
            currentAccountID: { 1 },
            fetchRemotePosition: { _, completion in
                completion(.success(remotePosition.value))
            },
            updateRemotePosition: { _, position, completion in
                remotePosition.value = position
                completion(.success(()))
            }
        )
    }
}

private enum OfflinePlaybackSyncTestError: Error, Equatable {
    case unavailable
}

private final class OfflinePlaybackRemotePosition {
    var value: Int

    init(value: Int) {
        self.value = value
    }
}
