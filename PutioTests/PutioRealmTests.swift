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
}
