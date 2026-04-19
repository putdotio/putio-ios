import XCTest
@testable import Putio
import RealmSwift
import UIKit

final class PutioKeychainTests: XCTestCase {
    func testTokenRoundTripUsesScopedServiceKey() {
        let serviceKey = "com.putio.tests.keychain.\(UUID().uuidString)"
        let keychain = PutioKeychain(serviceKey: serviceKey)

        keychain.clearToken()
        keychain.setToken("test-token")

        XCTAssertEqual(keychain.getToken(), "test-token")

        keychain.clearToken()
        XCTAssertNil(keychain.getToken())
    }
}

final class DownloadSupportTests: XCTestCase {
    func testInvalidURLReturnsNil() {
        XCTAssertNil(DownloadSupport.url(from: "", context: #function))
    }

    func testDeleteItemIfPresentDeletesExistingFileAndSucceedsForMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("asset.mp4")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("video".utf8))

        XCTAssertTrue(DownloadSupport.deleteItemIfPresent(at: fileURL, context: #function))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(DownloadSupport.deleteItemIfPresent(at: fileURL, context: #function))
    }
}

final class SettingsViewModelTests: XCTestCase {
    private var originalConfiguration: Realm.Configuration!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalConfiguration = Realm.Configuration.defaultConfiguration
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let configuration = PutioRealm.configuration(fileURL: temporaryDirectory.appendingPathComponent("Settings.realm"))
        Realm.Configuration.defaultConfiguration = configuration

        let realm = try XCTUnwrap(PutioRealm.open(context: "SettingsViewModelTests.setUp", configuration: configuration))
        let user = User()
        user.id = 1
        user.username = "tester"
        user.mail = "test@put.io"
        user.settings = UserSettings()
        user.disk = UserDisk()
        let config = UserConfig()

        XCTAssertTrue(PutioRealm.write(realm, context: "SettingsViewModelTests.setUp.write") {
            realm.add(user, update: .all)
            realm.add(config)
        })
    }

    override func tearDownWithError() throws {
        Realm.Configuration.defaultConfiguration = originalConfiguration
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        originalConfiguration = nil
        try super.tearDownWithError()
    }

    func testUpdateSelectedSortStateFallsBackToDefaultsForInvalidValue() throws {
        let viewModel = SettingsViewModel()
        let realm = try XCTUnwrap(PutioRealm.open(context: "SettingsViewModelTests.testUpdateSelectedSortStateFallsBackToDefaultsForInvalidValue"))
        XCTAssertTrue(PutioRealm.write(realm, context: "SettingsViewModelTests.invalidSort.write") {
            viewModel.settings.sortBy = "INVALID"
        })

        viewModel.updateSelectedSortState()

        XCTAssertEqual(viewModel.selectedSortByKey.key, "NAME")
        XCTAssertEqual(viewModel.selectedSortByDirection.key, "ASC")
    }

    func testBuildSectionsHidesConditionalSettingsWhenBackingFlagsAreDisabled() throws {
        let viewModel = SettingsViewModel()
        let realm = try XCTUnwrap(PutioRealm.open(context: "SettingsViewModelTests.testBuildSectionsHidesConditionalSettingsWhenBackingFlagsAreDisabled"))
        XCTAssertTrue(PutioRealm.write(realm, context: "SettingsViewModelTests.sectionVisibility.write") {
            viewModel.settings.sortBy = "DATE_DESC"
            viewModel.settings.trashEnabled = false
            viewModel.settings.hideSubtitles = true
        })
        viewModel.update()

        let storageSection = try? XCTUnwrap(viewModel.sections.first(where: { $0.title == "Storage" }))
        let mediaSection = try? XCTUnwrap(viewModel.sections.first(where: { $0.title == "Media playback" }))

        XCTAssertEqual(storageSection?.items.first(where: { $0.title == "Manage your trash" })?.visible, false)
        XCTAssertEqual(mediaSection?.items.first(where: { $0.title == "Do not select subtitles by default" })?.visible, false)
        XCTAssertEqual(viewModel.selectedSortByKey.key, "DATE")
        XCTAssertEqual(viewModel.selectedSortByDirection.key, "DESC")
    }
}

final class DeeplinkManagerTests: XCTestCase {
    func testHandleURLReturnsFalseWhenManagerIsNotReady() {
        let manager = DeeplinkManager()

        XCTAssertFalse(manager.handleURL(url: URL(string: "https://put.io/history")!))
    }

    func testHandleStaticURLsSwitchToExpectedTabs() {
        let manager = DeeplinkManager()
        let tabBarController = makeTabBarController()
        manager.tabBarController = tabBarController
        manager.isReadyToHandleURL = true

        XCTAssertTrue(manager.handleURL(url: URL(string: "https://put.io/history")!))
        XCTAssertEqual(tabBarController.selectedIndex, 1)

        XCTAssertTrue(manager.handleURL(url: URL(string: "https://put.io/settings")!))
        XCTAssertEqual(tabBarController.selectedIndex, 3)
    }

    private func makeTabBarController() -> MainTabBarController {
        let tabBarController = MainTabBarController()
        tabBarController.viewControllers = [
            makeNavigationController(title: MainTabBarController.TabbarItemTitle.files.rawValue),
            makeNavigationController(title: MainTabBarController.TabbarItemTitle.history.rawValue),
            makeNavigationController(title: MainTabBarController.TabbarItemTitle.downloads.rawValue),
            makeNavigationController(title: MainTabBarController.TabbarItemTitle.account.rawValue)
        ]
        _ = tabBarController.view
        return tabBarController
    }

    private func makeNavigationController(title: String) -> UINavigationController {
        let navigationController = UINavigationController(rootViewController: UIViewController())
        navigationController.tabBarItem = UITabBarItem(title: title, image: nil, tag: 0)
        return navigationController
    }
}

final class DownloadedFilePresenterTests: XCTestCase {
    func testUpdateDownloadStateAsNotReachableMarksDownloadFailed() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadedFilePresenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let configuration = PutioRealm.configuration(fileURL: temporaryDirectory.appendingPathComponent("Downloads.realm"))
        let realm = try XCTUnwrap(PutioRealm.open(context: "DownloadedFilePresenterTests.testUpdateDownloadStateAsNotReachableMarksDownloadFailed", configuration: configuration))

        let download = Download()
        download.id = 77
        download.name = "Episode"
        download.state = .completed
        download.fileType = .video

        XCTAssertTrue(PutioRealm.write(realm, context: "DownloadedFilePresenterTests.seed") {
            realm.add(download, update: .all)
        })

        let managedDownload = try XCTUnwrap(realm.object(ofType: Download.self, forPrimaryKey: 77))
        PresenterSpyViewController().updateDownloadStateAsNotReachable(managedDownload)

        XCTAssertEqual(managedDownload.state, .failed)
        XCTAssertEqual(managedDownload.message, "File not reachable")
    }

    private final class PresenterSpyViewController: UIViewController, DownloadedFilePresenter {}
}
