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

        let recoveredAudioURL = temporaryDirectory.appendingPathComponent("putio_adm_123.mp3")
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
        XCTAssertFalse(PutioRealm.needsDownloadRecovery(defaults: defaults))
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
}
