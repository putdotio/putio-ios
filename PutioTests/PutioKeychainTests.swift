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

    func testTokenOwnerBelongsOnlyToTheTokenItWasSavedWith() {
        let keychain = PutioKeychain(serviceKey: "com.putio.tests.keychain.\(UUID().uuidString)", legacyServiceKey: nil)
        addTeardownBlock { keychain.clearToken() }

        keychain.setTokenOwner(accountID: 1, for: "token-a")
        XCTAssertNil(keychain.tokenOwnerID)

        keychain.setToken("token-a")
        keychain.setTokenOwner(accountID: 1, for: "token-a")
        keychain.setToken("token-a")
        XCTAssertEqual(keychain.tokenOwnerID, 1)

        keychain.setToken("token-b")
        XCTAssertNil(keychain.tokenOwnerID)

        keychain.setTokenOwner(accountID: 1, for: "token-a")
        XCTAssertNil(keychain.tokenOwnerID, "a late answer for an earlier token must not claim this one")

        keychain.setTokenOwner(accountID: 2, for: "token-b")
        keychain.clearToken()
        keychain.setToken("token-b")
        XCTAssertNil(keychain.tokenOwnerID)
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

    func testAccountShowsOnePrivacyControlsRowWithTheCurrentState() throws {
        let viewModel = SettingsViewModel()
        let sections = viewModel.buildSections()
        let privacy = try XCTUnwrap(sections.first { $0.title == "Privacy and safety" })
        let next = try XCTUnwrap(sections.firstIndex { $0.title == "Privacy and safety" }) + 1

        XCTAssertEqual(sections[next].title, "Support", "the controls moved to their own page")
        XCTAssertFalse(sections.flatMap(\.items).contains { ["Strictly necessary", "Diagnostics", "Product analytics"].contains($0.title) })
        XCTAssertNil(privacy.footer)

        let row = try XCTUnwrap(privacy.items.last)
        XCTAssertEqual(row.title, "Privacy controls")
        XCTAssertEqual(row.type, .link)
        XCTAssertNotNil(row.action)
        XCTAssertEqual(row.subtitle, "Diagnostics on · Product analytics off")

        let realm = try XCTUnwrap(PutioRealm.open(context: #function))
        XCTAssertTrue(PutioRealm.write(realm, context: #function) {
            viewModel.settings.diagnosticsEnabled = false
            viewModel.settings.productAnalyticsEnabled = true
        })
        viewModel.update()

        let updated = viewModel.sections.flatMap(\.items).first { $0.title == "Privacy controls" }
        XCTAssertEqual(updated?.subtitle, "Diagnostics off · Product analytics on")
    }

    func testPrivacyControlsPageHasTheThreeControlsThenThePolicyLinks() throws {
        let sections = SettingsViewModel().privacyControlsSections()
        XCTAssertEqual(sections.count, 2)
        let controls = sections[0].items

        XCTAssertEqual(controls.map(\.title), ["Strictly necessary", "Diagnostics", "Product analytics"])
        XCTAssertEqual(controls.map(\.type), [.text, .toggle, .toggle])
        XCTAssertEqual(controls[0].value as? String, "Always on")
        XCTAssertNil(controls[0].action)
        XCTAssertEqual(controls.map(\.subtitle), [
            "Needed for sign-in, security, transfers, downloads, playback, billing, and saving your choices.",
            "Crash reports, error details, and limited playback diagnostics, so we can fix problems.",
            "Limited usage, device, billing, and playback data that shows which apps and features work."
        ])
        XCTAssertEqual(sections[0].footer, "Diagnostics and product analytics never send filenames, media titles, URLs, search text, or tokens.")

        XCTAssertEqual(sections[1].items.map(\.title), ["Privacy policy", "Services we use"])
        XCTAssertEqual(sections[1].items.map(\.type), [.link, .link])
        XCTAssertNil(sections[1].footer)
    }

    func testPolicyLinksOpenThePrivacyPolicyAndTheServicesPutioUses() throws {
        let viewModel = SettingsViewModel()
        let page = PrivacyControlsPageSpy(viewModel: viewModel)
        viewModel.privacyControlsViewController = page

        for item in viewModel.privacyControlsSections()[1].items {
            try XCTUnwrap(item.action, item.title)()
        }

        XCTAssertEqual(page.openedURLs.map(\.absoluteString), [
            "https://put.io/privacy-policy/?webview",
            "https://put.io/services-we-use?webview"
        ])
    }

    func testPrivacySwitchesReadTheirDescriptionToVoiceOver() throws {
        let toggles = SettingsViewModel().privacyControlsSections()[0].items.filter { $0.type == .toggle }

        for item in toggles {
            let cell = SettingsTableViewCell(style: .subtitle, reuseIdentifier: SettingsTableViewCell.subtitleReuseIdentifier)
            cell.configure(with: item)
            let control = try XCTUnwrap(cell.accessoryView as? UISwitch, item.title)
            XCTAssertEqual(control.accessibilityLabel, item.title)
            XCTAssertEqual(control.accessibilityHint, item.subtitle)
            XCTAssertNotNil(control.accessibilityHint)
        }
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

    func testPrivacyControlsRowOpensThePageWhoseSwitchesSaveThroughPutioAndTheAccountRowFollows() throws {
        var patches: [PutioAccountSettingsPatch] = []
        var pendingSave: ((Result<Void, PutioSDKError>) -> Void)?
        let viewModel = SettingsViewModel(
            saveAccountSettingsRequest: { update, completion in
                if case .patch(let patch) = update { patches.append(patch) }
                pendingSave = completion
            },
            markProductAnalyticsPromptAnsweredRequest: { $0(.success(())) },
            applyDiagnostics: { _ in },
            applyProductAnalytics: { _, _ in },
            fetchAccountInfoRequest: { _ in }
        )
        let account = try storyboardAccount()
        account.viewModel = viewModel
        let navigation = try pushOnWindow(account)

        let row = try XCTUnwrap(displayedCell(titled: "Privacy controls", in: account.tableView), "Account should show a Privacy controls row")
        XCTAssertEqual(row.cell.detailTextLabel?.text, "Diagnostics on · Product analytics off")
        for title in ["Strictly necessary", "Diagnostics", "Product analytics"] {
            XCTAssertNil(displayedCell(titled: title, in: account.tableView), "\(title) lives on the Privacy controls page")
        }
        try tapRow(at: row.indexPath, in: account.tableView)

        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (navigation.topViewController as? PrivacyControlsViewController)?.viewIfLoaded?.window != nil
                && navigation.transitionCoordinator == nil
        }, object: nil)
        wait(for: [shown], timeout: 5)
        let page = try XCTUnwrap(navigation.topViewController as? PrivacyControlsViewController)
        XCTAssertEqual(page.navigationItem.title, "Privacy controls")
        let texts = pageTexts(page)
        for copy in [
            "Always on",
            "Needed for sign-in, security, transfers, downloads, playback, billing, and saving your choices.",
            "Diagnostics and product analytics never send filenames, media titles, URLs, search text, or tokens.",
            "Privacy policy",
            "Services we use"
        ] {
            XCTAssertTrue(texts.contains(copy), copy)
        }
        XCTAssertEqual(try switchValue("Diagnostics", on: page), true)
        XCTAssertEqual(try switchValue("Product analytics", on: page), false)

        try flipSwitch("Diagnostics", on: page)
        try finishSave(&pendingSave, on: page)
        XCTAssertEqual(patches.map(\.diagnosticsEnabled), [false])
        XCTAssertEqual(try switchValue("Diagnostics", on: page), false)

        try flipSwitch("Product analytics", on: page)
        try finishSave(&pendingSave, on: page)
        XCTAssertEqual(patches.map(\.productAnalyticsEnabled), [nil, true])
        XCTAssertEqual(try switchValue("Product analytics", on: page), true)

        navigation.popViewController(animated: false)
        account.view.layoutIfNeeded()
        let updated = try XCTUnwrap(displayedCell(titled: "Privacy controls", in: account.tableView))
        XCTAssertEqual(updated.cell.detailTextLabel?.text, "Diagnostics off · Product analytics on")
    }

    private func storyboardAccount() throws -> SettingsTableViewController {
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: SettingsTableViewController.self))
        let tabBar = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "MainTabBarController") as? UITabBarController)
        let tab = try XCTUnwrap(tabBar.viewControllers?.compactMap { $0 as? UINavigationController }.first { $0.viewControllers.first is SettingsTableViewController })
        let account = try XCTUnwrap(tab.viewControllers.first as? SettingsTableViewController)
        tab.viewControllers = []
        return account
    }

    private func finishSave(_ pendingSave: inout ((Result<Void, PutioSDKError>) -> Void)?, on page: PrivacyControlsViewController) throws {
        _ = try waitForAlert(on: page, titled: "Saving...")
        try XCTUnwrap(pendingSave, "the switch should send its setting to put.io")(.success(()))
        pendingSave = nil
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in page.presentedViewController == nil }, object: nil)
        wait(for: [saved], timeout: 5)
    }

    private func displayedCell(titled title: String, in tableView: UITableView) -> (cell: UITableViewCell, indexPath: IndexPath)? {
        for indexPath in displayedIndexPaths(in: tableView) {
            tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
            tableView.layoutIfNeeded()
            if let cell = tableView.cellForRow(at: indexPath), cell.textLabel?.text == title {
                return (cell, indexPath)
            }
        }
        return nil
    }

    private func displayedIndexPaths(in tableView: UITableView) -> [IndexPath] {
        (0..<tableView.numberOfSections).flatMap { section in
            (0..<tableView.numberOfRows(inSection: section)).map { IndexPath(row: $0, section: section) }
        }
    }

    private func pageTexts(_ page: PrivacyControlsViewController) -> Set<String> {
        let tableView = page.tableView!
        let cellTexts = displayedIndexPaths(in: tableView).flatMap { indexPath -> [String] in
            tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
            tableView.layoutIfNeeded()
            guard let cell = tableView.cellForRow(at: indexPath) else { return [] }
            return [cell.textLabel?.text, cell.detailTextLabel?.text, (cell.accessoryView as? UILabel)?.text].compactMap { $0 }
        }
        let footers = (0..<tableView.numberOfSections).compactMap { page.tableView(tableView, titleForFooterInSection: $0) }
        return Set(cellTexts + footers)
    }

    private func pageSwitch(_ title: String, on page: PrivacyControlsViewController) throws -> UISwitch {
        let row = try XCTUnwrap(displayedCell(titled: title, in: page.tableView), title)
        return try XCTUnwrap(row.cell.accessoryView as? UISwitch, title)
    }

    private func switchValue(_ title: String, on page: PrivacyControlsViewController) throws -> Bool {
        try pageSwitch(title, on: page).isOn
    }

    private func flipSwitch(_ title: String, on page: PrivacyControlsViewController) throws {
        let control = try pageSwitch(title, on: page)
        control.isOn.toggle()
        control.sendActions(for: .valueChanged)
    }

    func testSignedInScreensAreReleasedWhenTheAppLeavesThem() throws {
        let deeplinkReadiness = DeeplinkManager.sharedInstance.isReadyToHandleURL
        addTeardownBlock { DeeplinkManager.sharedInstance.isReadyToHandleURL = deeplinkReadiness }
        weak var releasedTabBar: MainTabBarController?
        weak var releasedDownloads: DownloadsViewController?
        weak var releasedAccount: SettingsViewModel?
        var releasedScreens: [() -> UIViewController?] = []

        try autoreleasepool {
            let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: MainTabBarController.self))
            let tabBar = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "MainTabBarController") as? MainTabBarController)
            tabBar.loadViewIfNeeded()
            XCTAssertNotNil(tabBar.notificationToken)
            let screens = tabBar.viewControllers?
                .compactMap { $0 as? UINavigationController }
                .flatMap(\.viewControllers) ?? []
            let downloads = try XCTUnwrap(screens.compactMap { $0 as? DownloadsViewController }.first)
            downloads.loadViewIfNeeded()
            XCTAssertNotNil(downloads.notificationToken)
            let account = try XCTUnwrap(screens.compactMap { $0 as? SettingsTableViewController }.first)
            XCTAssertFalse(account.viewModel.notificationTokens.isEmpty)

            releasedTabBar = tabBar
            releasedDownloads = downloads
            releasedAccount = account.viewModel
            releasedScreens = screens.map { screen in { [weak screen] in screen } }
        }

        XCTAssertNil(releasedTabBar)
        XCTAssertNil(releasedDownloads)
        XCTAssertNil(releasedAccount)
        XCTAssertFalse(releasedScreens.isEmpty)
        XCTAssertEqual(releasedScreens.compactMap { $0() }.map { String(describing: type(of: $0)) }, [])
    }

    func testAccountKeepsItsRowsWhenTheNextSignInReplacesTheSession() throws {
        let viewModel = SettingsViewModel()
        let nextUser = User()
        nextUser.id = 2
        nextUser.username = "next"
        nextUser.settings = UserSettings()
        nextUser.disk = UserDisk()
        let realm = try XCTUnwrap(PutioRealm.open(context: #function))
        XCTAssertTrue(PutioRealm.replaceUserSession(realm, user: nextUser, config: UserConfig(), context: #function))

        viewModel.update()

        let username = viewModel.sections.flatMap(\.items).first { $0.title == "Username" }
        XCTAssertEqual(username?.value as? String, "tester")
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

    func testAnAccountReadFromBeforeThePromptsAllowLeavesProductAnalyticsOn() throws {
        var reads: [(Result<PutioAccount, PutioSDKError>) -> Void] = []
        var applied: [Bool] = []
        let viewModel = SettingsViewModel(
            applyDiagnostics: { _ in },
            applyProductAnalytics: { _, enabled in applied.append(enabled) },
            fetchAccountInfoRequest: { reads.append($0) }
        )
        let before = try account(diagnosticsEnabled: true, productAnalyticsEnabled: false)

        viewModel.fetchData()
        ProductAnalyticsChoice.save(true, saveSetting: { _, saved in saved(.success(())) }, markAnswered: { $0(.success(())) }) { _ in }
        reads[0](.success(before))

        XCTAssertEqual(applied, [], "a read from before the Allow stopped capture")

        viewModel.fetchData()
        reads[1](.success(before))

        XCTAssertEqual(applied, [false], "a read that starts after the answer applies")
    }

    func testAnAnswerSavedAfterItsAccountSignedOutAppliesToNobody() {
        var held: ((Result<Void, PutioSDKError>) -> Void)?
        let before = SettingsViewModel.confirmedSaves

        ProductAnalyticsChoice.save(true, saveSetting: { _, saved in held = saved }, markAnswered: { $0(.success(())) }) { _ in }
        // What signing out does to the session.
        AccountNoticeStore.shared.clear()
        held?(.success(()))

        XCTAssertEqual(SettingsViewModel.confirmedSaves, before, "a late answer reached the next account's gate")
    }

    func testAnAccountReadThatOutlivesTheSessionLeavesProductAnalyticsAlone() throws {
        var reads: [(Result<PutioAccount, PutioSDKError>) -> Void] = []
        var applied: [Bool] = []
        let viewModel = SettingsViewModel(
            applyDiagnostics: { _ in },
            applyProductAnalytics: { _, enabled in applied.append(enabled) },
            fetchAccountInfoRequest: { reads.append($0) }
        )

        viewModel.fetchData()
        // What signing out does to the session.
        AccountNoticeStore.shared.clear()
        reads[0](.success(try account(diagnosticsEnabled: true, productAnalyticsEnabled: true)))

        XCTAssertEqual(applied, [], "a read from before the sign-out restarted capture")
    }

    func testAnAccountReadFromBeforeAForegroundRefreshLeavesProductAnalyticsToIt() throws {
        var reads: [(Result<PutioAccount, PutioSDKError>) -> Void] = []
        var applied: [Bool] = []
        let viewModel = SettingsViewModel(
            applyDiagnostics: { _ in },
            applyProductAnalytics: { _, enabled in applied.append(enabled) },
            fetchAccountInfoRequest: { reads.append($0) }
        )

        viewModel.fetchData()
        // Away while another device turned it off; the refresh reads the account again.
        SettingsViewModel.accountRefreshes += 1
        reads[0](.success(try account(diagnosticsEnabled: true, productAnalyticsEnabled: true)))

        XCTAssertEqual(applied, [], "a read from before the refresh restarted capture")

        viewModel.fetchData()
        reads[1](.success(try account(diagnosticsEnabled: true, productAnalyticsEnabled: false)))

        XCTAssertEqual(applied, [false], "a read that starts after the refresh applies")
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
        let items = viewModel.privacyControlsSections().flatMap(\.items)
        return ["Diagnostics", "Product analytics"].compactMap { title in
            items.first { $0.title == title }?.value as? Bool
        }
    }

    private func toggle(_ title: String, in viewModel: SettingsViewModel) throws {
        let items = (viewModel.sections + viewModel.privacyControlsSections()).flatMap(\.items)
        let item = try XCTUnwrap(items.first { $0.title == title })
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

    private final class PrivacyControlsPageSpy: PrivacyControlsViewController {
        var openedURLs: [URL] = []

        override func presentWebPage(_ url: URL) {
            openedURLs.append(url)
        }
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

        XCTAssertTrue(manager.handleURL(url: URL(string: "putio://history")!))
        XCTAssertEqual(tabBarController.selectedIndex, 1)

        XCTAssertTrue(manager.handleURL(url: URL(string: "putio://put.io/history")!))
        XCTAssertEqual(tabBarController.selectedIndex, 1)

        XCTAssertTrue(manager.handleURL(url: URL(string: "putio:///account")!))
        XCTAssertEqual(tabBarController.selectedIndex, 3)
    }

    func testOnlyTheExactRouteSendsTheDiagnosticsCheck() throws {
        let manager = DeeplinkManager()
        let tabBarController = makeTabBarController()
        manager.tabBarController = tabBarController
        manager.isReadyToHandleURL = true
        var checks = 0
        manager.diagnosticsCheck = {
            checks += 1
            return true
        }

        for near in ["putio:///diagnostics", "putio:///diagnostics-checks", "putio:///diagnostics-check/1", "putio://diagnostics/check"] {
            XCTAssertFalse(manager.handleURL(url: try XCTUnwrap(URL(string: near))), near)
        }
        XCTAssertEqual(checks, 0)

        for exact in ["putio:///diagnostics-check", "putio://diagnostics-check"] {
            XCTAssertTrue(manager.handleURL(url: try XCTUnwrap(URL(string: exact))), exact)
        }
        XCTAssertEqual(checks, 2)
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

    func testUnplayablePackageOffersRedownloadInsteadOfPlayer() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadedFilePresenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let configuration = PutioRealm.configuration(fileURL: temporaryDirectory.appendingPathComponent("Downloads.realm"))
        let realm = try XCTUnwrap(PutioRealm.open(context: "DownloadedFilePresenterTests.unplayablePackage", configuration: configuration))
        let download = Download()
        download.id = 9_000_401
        download.name = "Partial Episode"
        download.state = .completed
        download.fileType = .video
        XCTAssertTrue(PutioRealm.write(realm, context: "DownloadedFilePresenterTests.unplayablePackage.seed") {
            realm.add(download, update: .all)
        })
        let package = try makeEmptyPackage()
        let bookmarkKey = String(download.id)
        UserDefaults.standard.set(try package.bookmarkData(), forKey: bookmarkKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: bookmarkKey) }
        let viewController = PresenterSpyViewController()

        viewController.presentDownloadedFile(download)

        let alert = try XCTUnwrap(viewController.presentedAlert)
        XCTAssertEqual(alert.title, NSLocalizedString("File Unavailable", comment: ""))
        XCTAssertTrue(alert.actions.contains { $0.title == NSLocalizedString("Re-download", comment: "") })
        XCTAssertEqual(download.state, .failed)
    }

    func testFinishedTaskKeepsOnlyAPlayablePackage() throws {
        let package = try makeEmptyPackage()
        let taskError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)

        XCTAssertEqual(VideoDownloadManager.playablePackage(at: package, error: nil) { _ in true }, package)
        XCTAssertNil(VideoDownloadManager.playablePackage(at: package, error: taskError) { _ in true })
        XCTAssertNil(VideoDownloadManager.playablePackage(at: nil, error: nil) { _ in true })
        XCTAssertNil(VideoDownloadManager.playablePackage(at: package, error: nil))
    }

    private func makeEmptyPackage() throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadedFilePresenterTests-\(UUID().uuidString).movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        return package
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

        func deleteDownloadedFile(id: Int, fileType: Download.FileType, completion: @escaping (Bool) -> Void) {
            completion(deleteResult)
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
