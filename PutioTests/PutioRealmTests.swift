import XCTest
@testable import Putio
import PutioSDK
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

    /// `PutioTests/Fixtures/README.md` says how 2.58.0 wrote it.
    private func copyShipped258Realm() throws -> URL {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "putio-2.58.0", withExtension: "realm"))
        let realmURL = temporaryDirectory.appendingPathComponent("default.realm")
        try FileManager.default.copyItem(at: fixture, to: realmURL)
        return realmURL
    }

    /// The format of the header's selected slot (Realm's `SlabAlloc::Header`).
    private func realmFileFormat(at url: URL) throws -> UInt8 {
        let header = try XCTUnwrap(FileHandle(forReadingFrom: url).readToEnd()?.prefix(24))
        XCTAssertEqual(String(decoding: header[16..<20], as: UTF8.self), "T-DB")
        return header[20 + Int(header[23] & 1)]
    }

    private func preserveDefaultRealmConfiguration() {
        let configuration = Realm.Configuration.defaultConfiguration
        addTeardownBlock { Realm.Configuration.defaultConfiguration = configuration }
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

    func testShipped258RealmIsRejectedAsUnsupportedFormat() throws {
        let realmURL = try copyShipped258Realm()
        XCTAssertEqual(try realmFileFormat(at: realmURL), 9)

        XCTAssertThrowsError(try Realm(configuration: PutioRealm.configuration(fileURL: realmURL))) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, Realm.Error.errorDomain)
            XCTAssertEqual(error.code, Realm.Error.Code.unsupportedFileFormatVersion.rawValue)
        }
    }

    func testSetupReplacesShipped258RealmAndFlagsRecovery() throws {
        let realmURL = try copyShipped258Realm()
        let configuration = PutioRealm.configuration(fileURL: realmURL)
        preserveDefaultRealmConfiguration()

        XCTAssertNil(PutioRealm.setup(configuration: configuration, defaults: defaults))

        XCTAssertTrue(PutioRealm.needsDownloadRecovery(defaults: defaults))
        XCTAssertTrue(PutioRealm.isUpgradingFromShipped258(defaults: defaults))
        XCTAssertEqual(Realm.Configuration.defaultConfiguration.fileURL, realmURL)
        XCTAssertEqual(try realmFileFormat(at: realmURL), 24)
        // Realm's own copy of the rejected file, which would keep 2.58.0's rows.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.contains("backup") }
        XCTAssertEqual(leftovers, [])
        let realm = try XCTUnwrap(PutioRealm.open(context: #function, configuration: configuration))
        XCTAssertTrue(realm.objects(User.self).isEmpty)
        XCTAssertTrue(realm.objects(Download.self).isEmpty)
    }

    func testRecoveryRebuildsShipped258AudioAndVideoDownloads() throws {
        let realmURL = try copyShipped258Realm()
        let configuration = PutioRealm.configuration(fileURL: realmURL)
        preserveDefaultRealmConfiguration()
        XCTAssertNil(PutioRealm.setup(configuration: configuration, defaults: defaults))

        // What 2.58.0's AudioDownloadManager and VideoDownloadManager kept outside Realm.
        let audioPath = "putio_adm_501_fixture-song.mp3"
        FileManager.default.createFile(atPath: temporaryDirectory.appendingPathComponent(audioPath).path, contents: Data("audio".utf8))
        defaults.set(audioPath, forKey: "501")
        let asset = temporaryDirectory.appendingPathComponent("fixture-movie_0123456789ABCDEF.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
        defaults.set(try asset.bookmarkData(), forKey: "502")

        let realm = try XCTUnwrap(PutioRealm.open(context: #function, configuration: configuration))
        PutioRealm.recoverDownloadsIfNeeded(
            defaults: defaults,
            documentsURL: temporaryDirectory,
            realm: realm,
            shouldEnrichPlaceholders: false
        )

        let audio = try XCTUnwrap(realm.object(ofType: Download.self, forPrimaryKey: 501))
        XCTAssertEqual(audio.fileType, .audio)
        XCTAssertEqual(audio.state, .completed)
        let video = try XCTUnwrap(realm.object(ofType: Download.self, forPrimaryKey: 502))
        XCTAssertEqual(video.fileType, .video)
        XCTAssertEqual(video.state, .completed)
        // The queued download had no file to recover.
        XCTAssertEqual(realm.objects(Download.self).count, 2)
        XCTAssertFalse(PutioRealm.needsDownloadRecovery(defaults: defaults))
    }

    func testSetupReplacesAFileThatIsNotARealm() throws {
        let realmURL = temporaryDirectory.appendingPathComponent("default.realm")
        try Data(repeating: 0x2A, count: 4096).write(to: realmURL)
        preserveDefaultRealmConfiguration()

        XCTAssertNil(PutioRealm.setup(configuration: PutioRealm.configuration(fileURL: realmURL), defaults: defaults))

        XCTAssertTrue(PutioRealm.needsDownloadRecovery(defaults: defaults))
        // Not 2.58.0's file, so a 2.58.0 token left beside it must not sign in.
        XCTAssertFalse(PutioRealm.isUpgradingFromShipped258(defaults: defaults))
        XCTAssertEqual(try realmFileFormat(at: realmURL), 24)
    }

    func testRecoveryKeepsRowsThatAreAlreadyThere() throws {
        let configuration = PutioRealm.configuration(fileURL: temporaryDirectory.appendingPathComponent("Existing.realm"))
        let realm = try XCTUnwrap(PutioRealm.open(context: #function, configuration: configuration))
        let existing = Download()
        existing.id = 501
        existing.name = "Downloaded Since.mp3"
        existing.state = .completed
        existing.fileType = .audio
        XCTAssertTrue(PutioRealm.write(realm, context: #function) { realm.add(existing) })
        for id in [501, 502] {
            let path = "putio_adm_\(id)_fixture.mp3"
            FileManager.default.createFile(atPath: temporaryDirectory.appendingPathComponent(path).path, contents: Data("audio".utf8))
            defaults.set(path, forKey: String(id))
        }

        PutioRealm.setNeedsDownloadRecovery(true, defaults: defaults)
        PutioRealm.recoverDownloadsIfNeeded(defaults: defaults, documentsURL: temporaryDirectory, realm: realm, shouldEnrichPlaceholders: false)

        XCTAssertEqual(realm.object(ofType: Download.self, forPrimaryKey: 501)?.name, "Downloaded Since.mp3")
        XCTAssertEqual(realm.object(ofType: Download.self, forPrimaryKey: 502)?.name, "Recovering...")
    }

    func testSetupFallsBackToMemoryWhenTheFileCannotOpen() throws {
        let realmURL = temporaryDirectory.appendingPathComponent("missing/default.realm")
        preserveDefaultRealmConfiguration()

        XCTAssertNotNil(PutioRealm.setup(configuration: PutioRealm.configuration(fileURL: realmURL), defaults: defaults))

        XCTAssertFalse(PutioRealm.needsDownloadRecovery(defaults: defaults))
        XCTAssertFalse(PutioRealm.isUpgradingFromShipped258(defaults: defaults))
        // Sign-in writes the user and lets go of its instance. The next open must
        // still find it, or every sign-in lands back on Login.
        autoreleasepool {
            let user = User()
            user.id = 4242
            guard let realm = PutioRealm.open(context: #function) else { return XCTFail("no fallback Realm") }
            XCTAssertTrue(PutioRealm.write(realm, context: #function) { realm.add(user) })
        }
        let realm = try XCTUnwrap(PutioRealm.open(context: #function))
        defer { try? realm.write { realm.deleteAll() } }
        XCTAssertNotNil(realm.object(ofType: User.self, forPrimaryKey: 4242))
    }

    // Before first unlock the open fails with an I/O error, not 16. Unless setup
    // runs again once the device unlocks, 2.58.0's token reads as a 3.x leftover.
    func testSetupStoppedByTheLockStillReplacesShipped258Realm() throws {
        let realmURL = temporaryDirectory.appendingPathComponent("locked/default.realm")
        preserveDefaultRealmConfiguration()
        XCTAssertNotNil(PutioRealm.setup(configuration: PutioRealm.configuration(fileURL: realmURL), defaults: defaults, isProtectedDataAvailable: false))
        XCTAssertFalse(PutioRealm.isUpgradingFromShipped258(defaults: defaults))

        // Unlocked, the file reads as 2.58.0's.
        try FileManager.default.createDirectory(at: realmURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "putio-2.58.0", withExtension: "realm"))
        try FileManager.default.copyItem(at: fixture, to: realmURL)

        XCTAssertNil(PutioRealm.setupIfLocked(defaults: defaults))
        XCTAssertTrue(PutioRealm.isUpgradingFromShipped258(defaults: defaults))
        XCTAssertEqual(try realmFileFormat(at: realmURL), 24)
    }

    func testSetupKeepsTheFileWhileProtectedDataIsUnavailable() throws {
        let realmURL = temporaryDirectory.appendingPathComponent("locked/default.realm")
        preserveDefaultRealmConfiguration()

        XCTAssertNotNil(PutioRealm.setup(configuration: PutioRealm.configuration(fileURL: realmURL), defaults: defaults, isProtectedDataAvailable: false))

        // Once the device unlocks, the next open reaches the file.
        try FileManager.default.createDirectory(at: realmURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let realm = try XCTUnwrap(PutioRealm.open(context: #function))
        XCTAssertNil(realm.configuration.inMemoryIdentifier)
        XCTAssertEqual(realm.configuration.fileURL, realmURL)
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

    func testLegacyOfflinePlaybackConflictFavorsRemotePosition() {
        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        store.enqueue(
            accountID: 1,
            fileID: 42,
            position: 800,
            expectedRemotePosition: 500
        )

        var appliedRemotePositions: [Int] = []
        var resolvedLocalPosition: Int?
        let synchronizer = OfflineVideoPlaybackPositionSynchronizer(
            store: store,
            currentAccountID: { 1 },
            fetchRemotePosition: { _, completion in completion(.success(0)) },
            updateRemotePosition: { _, position, completion in
                appliedRemotePositions.append(position)
                completion(.success(()))
            },
            resolveLocalConflict: { _, _, position in
                resolvedLocalPosition = position
                return true
            }
        )

        synchronizer.syncPendingUpdates()

        XCTAssertEqual(appliedRemotePositions, [])
        XCTAssertEqual(resolvedLocalPosition, 0)
        XCTAssertNil(store.pendingUpdate(for: 42, accountID: 1))
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

    func testReentrantSyncRetriesNewerPositionWithoutRepeatingRestoreMidPass() {
        let store = OfflineVideoPlaybackPositionStore(userDefaults: defaults)
        store.enqueue(
            accountID: 1,
            fileID: 42,
            position: 180,
            expectedRemotePosition: 120
        )

        var canRestore = true
        var restoreCallCount = 0
        var fetchCompletions: [(Result<Int, Error>) -> Void] = []
        var appliedPositions: [Int] = []
        let synchronizer = OfflineVideoPlaybackPositionSynchronizer(
            store: store,
            prepareForSync: {
                restoreCallCount += 1
                return canRestore
            },
            currentAccountID: { 1 },
            fetchRemotePosition: { _, completion in fetchCompletions.append(completion) },
            updateRemotePosition: { _, position, completion in
                appliedPositions.append(position)
                completion(.success(()))
            }
        )

        synchronizer.syncPendingUpdates()
        XCTAssertEqual(restoreCallCount, 1)
        XCTAssertEqual(fetchCompletions.count, 1)

        store.enqueue(accountID: 1, fileID: 42, position: 200, expectedRemotePosition: 120)
        canRestore = false
        synchronizer.syncPendingUpdates()
        XCTAssertEqual(restoreCallCount, 1)

        canRestore = true
        fetchCompletions[0](.success(120))
        XCTAssertEqual(restoreCallCount, 2)
        XCTAssertEqual(fetchCompletions.count, 2)

        fetchCompletions[1](.success(120))
        XCTAssertEqual(appliedPositions, [200])
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

    func testSchema12SessionOpensWithDiagnosticsOnAndProductAnalyticsOff() throws {
        let realm = try openSchema12Session(defaults: isolatedDefaults())

        let settings = try XCTUnwrap(realm.object(ofType: User.self, forPrimaryKey: 7)?.settings)
        XCTAssertFalse(settings.historyEnabled, "the user kept its own settings row")
        XCTAssertEqual(settings.sortBy, "NAME_ASC")
        XCTAssertEqual(realm.objects(UserSettings.self).map(\.diagnosticsEnabled), [true, true])
        XCTAssertEqual(realm.objects(UserSettings.self).map(\.productAnalyticsEnabled), [false, false])
    }

    func testSchema12SessionKeepsTheDiagnosticsOptOutSentryFollows() throws {
        let defaults = try isolatedDefaults()
        SentryTelemetry.update(diagnosticsEnabled: false, dsn: nil, defaults: defaults)

        let realm = try openSchema12Session(defaults: defaults)

        XCTAssertEqual(realm.objects(UserSettings.self).map(\.diagnosticsEnabled), [false, false])
    }

    func testUserSettingsCopyThePrivacyControlsFromTheAccount() throws {
        let account = try JSONDecoder().decode(
            PutioAccount.Settings.self,
            from: Data(#"{"diagnostics_enabled":false,"product_analytics_enabled":true}"#.utf8)
        )

        let settings = try XCTUnwrap(UserSettings(settings: account))

        XCTAssertFalse(settings.diagnosticsEnabled)
        XCTAssertTrue(settings.productAnalyticsEnabled)
    }

    /// A user with its own settings row, plus the row an earlier launch's
    /// replaceUserSession left behind, opened with the current configuration.
    private func openSchema12Session(defaults: UserDefaults) throws -> Realm {
        let realmURL = temporaryDirectory.appendingPathComponent("Schema12.realm")
        try autoreleasepool {
            let schema12 = Realm.Configuration(
                fileURL: realmURL,
                schemaVersion: 12,
                objectTypes: [Schema12User.self, Schema12UserSettings.self]
            )
            let realm = try Realm(configuration: schema12)
            try realm.write {
                let settings = Schema12UserSettings()
                settings.historyEnabled = false
                settings.sortBy = "NAME_ASC"
                let user = Schema12User()
                user.id = 7
                user.settings = settings
                realm.add(user)
                realm.add(Schema12UserSettings())
            }
        }

        let configuration = PutioRealm.configuration(fileURL: realmURL, defaults: defaults)
        return try XCTUnwrap(PutioRealm.open(context: #function, configuration: configuration))
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "PutioRealmTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
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

// Schema 12 as 3.0.0 shipped it, cut to the tables the version 13 step changes.
// Out of the default schema, which would otherwise hold two of each.
final class Schema12User: Object {
    @objc dynamic var id = 0
    @objc dynamic var settings: Schema12UserSettings?

    override static func primaryKey() -> String? { "id" }
    override class func _realmObjectName() -> String? { "User" }
    override class func shouldIncludeInDefaultSchema() -> Bool { false }
}

final class Schema12UserSettings: Object {
    @objc dynamic var routeName = ""
    @objc dynamic var suggestNextVideo = false
    @objc dynamic var rememberVideoTime = false
    @objc dynamic var historyEnabled = true
    @objc dynamic var trashEnabled = true
    @objc dynamic var sortBy = ""
    @objc dynamic var showOptimisticUsage = false
    @objc dynamic var twoFactorEnabled = false
    @objc dynamic var hideSubtitles = false
    @objc dynamic var dontAutoSelectSubtitles = false

    override class func _realmObjectName() -> String? { "UserSettings" }
    override class func shouldIncludeInDefaultSchema() -> Bool { false }
}
