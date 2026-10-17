import XCTest
@testable import Putio
import PutioSDK
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

    // 2.58.0 wrote the token under its own literal service, not this build's.
    func testShipped258TokenMovesToTheCurrentService() {
        let serviceKey = "com.putio.tests.keychain.\(UUID().uuidString)"
        let legacyServiceKey = "\(serviceKey).2.58.0"
        let shipped = PutioKeychain(serviceKey: legacyServiceKey, legacyServiceKey: nil)
        shipped.setToken("shipped-token")
        let keychain = PutioKeychain(serviceKey: serviceKey, legacyServiceKey: legacyServiceKey)
        addTeardownBlock { keychain.clearToken() }

        XCTAssertEqual(keychain.getToken(adoptsShipped258Token: true), "shipped-token")
        XCTAssertNil(shipped.getToken())
        XCTAssertEqual(PutioKeychain(serviceKey: serviceKey, legacyServiceKey: nil).getToken(), "shipped-token")

        // Signing out must not leave the old copy to sign back in with.
        shipped.setToken("shipped-token")
        keychain.clearToken()
        XCTAssertNil(keychain.getToken(adoptsShipped258Token: true))
    }

    // A 3.x sign-out cleared only 3.x's service, so on an install 3.x already
    // ran, 2.58.0's copy must not sign anyone back in.
    func testShipped258TokenIsDeletedWhenNotAdopted() {
        let serviceKey = "com.putio.tests.keychain.\(UUID().uuidString)"
        let legacyServiceKey = "\(serviceKey).2.58.0"
        let shipped = PutioKeychain(serviceKey: legacyServiceKey, legacyServiceKey: nil)
        shipped.setToken("shipped-token")
        let keychain = PutioKeychain(serviceKey: serviceKey, legacyServiceKey: legacyServiceKey)
        addTeardownBlock { keychain.clearToken() }

        XCTAssertNil(keychain.getToken())
        XCTAssertNil(shipped.getToken())
        XCTAssertNil(keychain.getToken(adoptsShipped258Token: true))
    }

    // 2.58.0's own service, not one the test names: the default is the upgrade.
    func testDefaultKeychainReadsTheServiceThat258Shipped() {
        let shipped = PutioKeychain(serviceKey: "com.putio.tvOS", legacyServiceKey: nil)
        shipped.setToken("shipped-token")
        let keychain = PutioKeychain(serviceKey: "com.putio.tests.keychain.\(UUID().uuidString)")
        addTeardownBlock {
            keychain.clearToken()
            shipped.clearToken()
        }

        XCTAssertEqual(keychain.getToken(adoptsShipped258Token: true), "shipped-token")
        XCTAssertNil(shipped.getToken())
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

    func testBuildSectionsIncludesDownloadConcurrencySetting() {
        let limit = DownloadConcurrencyPreference.limit()

        let downloadsSection = SettingsViewModel().buildSections().first { $0.title == "Downloads" }

        XCTAssertEqual(downloadsSection?.items.first?.title, "Simultaneous downloads")
        XCTAssertEqual(downloadsSection?.items.first?.value as? String, "\(limit) at a time")
    }

    func testPrivacyControlsFollowPrivacyAndSafetyWithTheContractCopy() throws {
        let sections = SettingsViewModel().buildSections()
        let start = try XCTUnwrap(sections.firstIndex { $0.title == "Privacy and safety" }) + 1
        let controls = Array(sections[start..<start + 3])

        XCTAssertEqual(controls.map(\.title), ["Privacy controls", "", ""])
        XCTAssertEqual(sections[start + 3].title, "Support")
        XCTAssertEqual(controls.flatMap(\.items).map(\.title), ["Strictly necessary", "Diagnostics", "Product analytics"])
        XCTAssertEqual(controls.flatMap(\.items).map(\.type), [.text, .toggle, .toggle])
        XCTAssertEqual(controls[0].items[0].value as? String, "Always on")
        XCTAssertNil(controls[0].items[0].action)
        XCTAssertEqual(controls.map(\.footer), [
            "Required for login, security, account access, transfers, downloads, playback, billing operations, and remembering your choices. These cannot be turned off.",
            "Send crash reports, error details, and limited playback diagnostics so we can find and fix problems. We do not send filenames, media titles, URLs, search text, or tokens.",
            "Help us understand which apps and features work well by sending limited usage, device, billing, and playback information. We never send filenames, media titles, URLs, search text, or tokens."
        ])
    }

    func testPrivacySwitchesShowTheStoredSettings() throws {
        let viewModel = SettingsViewModel()
        XCTAssertEqual(privacyValues(viewModel), [true, false])

        let realm = try XCTUnwrap(PutioRealm.open(context: #function))
        XCTAssertTrue(PutioRealm.write(realm, context: #function) {
            viewModel.settings.diagnosticsEnabled = false
            viewModel.settings.productAnalyticsEnabled = true
        })
        viewModel.update()

        XCTAssertEqual(privacyValues(viewModel), [false, true])
    }

    func testDiagnosticsSwitchSavesThePatchAndAppliesItBeforeTheLocalWrite() throws {
        var patches: [PutioAccountSettingsPatch] = []
        var applied: [(value: Bool, storedAtTheTime: Bool)] = []
        var viewModel: SettingsViewModel!
        viewModel = SettingsViewModel(
            saveAccountSettingsRequest: { update, completion in
                if case .patch(let patch) = update { patches.append(patch) }
                completion(.success(()))
            },
            markProductAnalyticsPromptAnsweredRequest: { _ in XCTFail("diagnostics is not the prompt's answer") },
            applyDiagnostics: { applied.append(($0, viewModel.settings.diagnosticsEnabled)) }
        )
        attachSpy(to: viewModel)

        try toggle("Diagnostics", in: viewModel)

        XCTAssertEqual(patches.map(\.diagnosticsEnabled), [false])
        XCTAssertEqual(patches.map(\.productAnalyticsEnabled), [nil])
        XCTAssertEqual(applied.map(\.value), [false])
        XCTAssertEqual(applied.map(\.storedAtTheTime), [true])
        XCTAssertFalse(viewModel.settings.diagnosticsEnabled)
        XCTAssertEqual(privacyValues(viewModel), [false, false])
    }

    func testProductAnalyticsSwitchSavesTheSettingThenAnswersThePrompt() throws {
        var writes: [String] = []
        let viewModel = SettingsViewModel(
            saveAccountSettingsRequest: { update, completion in
                if case .patch(let patch) = update {
                    writes.append("setting: \(String(describing: patch.productAnalyticsEnabled))")
                }
                completion(.success(()))
            },
            markProductAnalyticsPromptAnsweredRequest: { completion in
                writes.append("answer")
                completion(.success(()))
            },
            applyDiagnostics: { _ in XCTFail("analytics must not touch Sentry") }
        )
        attachSpy(to: viewModel)

        try toggle("Product analytics", in: viewModel)

        XCTAssertEqual(writes, ["setting: Optional(true)", "answer"])
        XCTAssertTrue(viewModel.settings.productAnalyticsEnabled)
    }

    func testProductAnalyticsSwitchKeepsTheSettingWhenOnlyTheAnswerFails() throws {
        let viewModel = SettingsViewModel(
            saveAccountSettingsRequest: { _, completion in completion(.success(())) },
            markProductAnalyticsPromptAnsweredRequest: { completion in
                completion(.failure(.offline("/config/dismissed.product_analytics_prompt")))
            }
        )
        let spy = attachSpy(to: viewModel)

        try toggle("Product analytics", in: viewModel)

        XCTAssertTrue(viewModel.settings.productAnalyticsEnabled)
        XCTAssertEqual(spy.presentedAlerts.map(\.title), ["Saving..."])
    }

    func testFailedPrivacySaveSaysSoAndKeepsTheStoredValue() throws {
        for title in ["Diagnostics", "Product analytics"] {
            var answered = false
            var applied = false
            let viewModel = SettingsViewModel(
                saveAccountSettingsRequest: { _, completion in completion(.failure(.offline("/account/settings"))) },
                markProductAnalyticsPromptAnsweredRequest: { _ in answered = true },
                applyDiagnostics: { _ in applied = true }
            )
            let spy = attachSpy(to: viewModel)
            let before = privacyValues(viewModel)

            try toggle(title, in: viewModel)

            let alert = try XCTUnwrap(spy.presentedAlerts.last, title)
            XCTAssertEqual(alert.title, "Couldn't save setting", title)
            XCTAssertEqual(alert.message, "Network error\nPlease check your internet connection and try again.", title)
            XCTAssertEqual(privacyValues(viewModel), before, title)
            XCTAssertFalse(answered, title)
            XCTAssertFalse(applied, title)
        }
    }

    func testOtherSwitchesKeepTheirFailureAlert() throws {
        let viewModel = SettingsViewModel(
            saveAccountSettingsRequest: { _, completion in completion(.failure(.offline("/account/settings"))) }
        )
        let spy = attachSpy(to: viewModel)

        try toggle("Show subtitles", in: viewModel)

        XCTAssertEqual(spy.presentedAlerts.last?.title, "Network error")
    }

    func testAnAccountReadFromBeforeASaveLeavesTheSavedPrivacySettings() throws {
        var reads: [(Result<PutioAccount, PutioSDKError>) -> Void] = []
        var applied: [Bool] = []
        let viewModel = SettingsViewModel(
            saveAccountSettingsRequest: { _, completion in completion(.success(())) },
            markProductAnalyticsPromptAnsweredRequest: { completion in completion(.success(())) },
            applyDiagnostics: { applied.append($0) },
            fetchAccountInfoRequest: { reads.append($0) }
        )
        attachSpy(to: viewModel)
        let before = try account(diagnosticsEnabled: true, productAnalyticsEnabled: false)

        viewModel.fetchData()
        try toggle("Diagnostics", in: viewModel)
        try toggle("Product analytics", in: viewModel)
        reads[0](.success(before))

        XCTAssertEqual(applied, [false])
        XCTAssertEqual(privacyValues(viewModel), [false, true])

        viewModel.fetchData()
        reads[1](.success(before))

        XCTAssertEqual(applied, [false, true], "a read that starts after the save applies")
        XCTAssertEqual(privacyValues(viewModel), [true, false])
    }

    private func account(diagnosticsEnabled: Bool, productAnalyticsEnabled: Bool) throws -> PutioAccount {
        let json = """
        {
          "user_id": 1, "username": "tester", "mail": "test@put.io",
          "account_active": true, "account_status": "active", "is_sub_account": false,
          "disk": { "avail": 0, "size": 0, "used": 0 },
          "settings": { "diagnostics_enabled": \(diagnosticsEnabled), "product_analytics_enabled": \(productAnalyticsEnabled) }
        }
        """
        return try JSONDecoder().decode(PutioAccount.self, from: Data(json.utf8))
    }

    private func privacyValues(_ viewModel: SettingsViewModel) -> [Bool] {
        let items = viewModel.sections.flatMap(\.items)
        return ["Diagnostics", "Product analytics"].compactMap { title in
            items.first { $0.title == title }?.value as? Bool
        }
    }

    private func toggle(_ title: String, in viewModel: SettingsViewModel) throws {
        let item = try XCTUnwrap(viewModel.sections.flatMap(\.items).first { $0.title == title })
        let action = try XCTUnwrap(item.action, title)
        action()
    }

    @discardableResult
    private func attachSpy(to viewModel: SettingsViewModel) -> SettingsPresenterSpy {
        let spy = SettingsPresenterSpy(style: .insetGrouped)
        viewModel.tableViewController = spy
        addTeardownBlock { _ = spy }
        return spy
    }

    private final class SettingsPresenterSpy: SettingsTableViewController {
        var presentedAlerts: [UIAlertController] = []

        override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            if let alert = viewControllerToPresent as? UIAlertController {
                presentedAlerts.append(alert)
            }
            completion?()
        }
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

    func testOnlyTheExactPathSendsTheDiagnosticsCheck() throws {
        let manager = DeeplinkManager()
        let tabBarController = makeTabBarController()
        manager.tabBarController = tabBarController
        manager.isReadyToHandleURL = true
        var checks = 0
        manager.diagnosticsCheck = {
            checks += 1
            return true
        }

        for near in ["putio://diagnostics-check", "putio:///diagnostics", "putio:///diagnostics-checks", "putio:///diagnostics-check/1"] {
            XCTAssertFalse(manager.handleURL(url: try XCTUnwrap(URL(string: near))), near)
        }
        XCTAssertEqual(checks, 0)

        XCTAssertTrue(manager.handleURL(url: try XCTUnwrap(URL(string: "putio:///diagnostics-check"))))
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(tabBarController.selectedIndex, 0, "the check changed the visible screen")
    }

    func testTabIconsDoNotDependOnLocalizedTitles() throws {
        let tabBarController = makeTabBarController()
        let items = try XCTUnwrap(tabBarController.tabBar.items)

        XCTAssertEqual(items.count, 4)
        for item in items {
            XCTAssertEqual(item.image?.size, CGSize(width: 24, height: 24))
            XCTAssertEqual(item.selectedImage?.size, CGSize(width: 24, height: 24))
        }
    }

    private func makeTabBarController() -> MainTabBarController {
        let tabBarController = MainTabBarController()
        tabBarController.viewControllers = [
            makeNavigationController(tab: .files, title: "Dateien"),
            makeNavigationController(tab: .history, title: "Verlauf"),
            makeNavigationController(tab: .downloads, title: "Downloads"),
            makeNavigationController(tab: .account, title: "Konto")
        ]
        _ = tabBarController.view
        tabBarController.configureTabBarIcons()
        return tabBarController
    }

    private func makeNavigationController(tab: MainTabBarController.Tab, title: String) -> UINavigationController {
        let navigationController = UINavigationController(rootViewController: UIViewController())
        navigationController.tabBarItem = UITabBarItem(title: title, image: nil, tag: tab.rawValue)
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

    func testFailedDeleteFromRestartAlertPresentsRecoveryMessage() throws {
        let download = Download()
        download.id = 77
        download.name = "Episode"
        download.fileType = .video

        let viewController = PresenterSpyViewController()
        viewController.deleteResult = false
        viewController.handleDeleteDownloadedFile(download)

        let alert = try XCTUnwrap(viewController.presentedAlert)
        XCTAssertEqual(alert.title, NSLocalizedString("Couldn't Delete Download", comment: ""))
        XCTAssertEqual(
            alert.message,
            NSLocalizedString(
                "The download couldn't be deleted. Try again from Downloads, or remove it from the list; the file may remain on this device.",
                comment: ""
            )
        )
        XCTAssertEqual(alert.actions.map(\.title), [NSLocalizedString("Close", comment: "")])
    }

    private final class PresenterSpyViewController: UIViewController, DownloadedFilePresenter {
        var deleteResult = true
        var presentedAlert: UIAlertController?

        func deleteDownloadedFile(_ download: Download) -> Bool {
            deleteResult
        }

        override func present(
            _ viewControllerToPresent: UIViewController,
            animated flag: Bool,
            completion: (() -> Void)? = nil
        ) {
            presentedAlert = viewControllerToPresent as? UIAlertController
            completion?()
        }
    }
}
