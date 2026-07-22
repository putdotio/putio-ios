import XCTest
@testable import Putio

final class AppearanceManagerTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppearanceManager.defaultsKey)
        super.tearDown()
    }

    func testDefaultsToSystemWhenUnset() {
        UserDefaults.standard.removeObject(forKey: AppearanceManager.defaultsKey)
        XCTAssertEqual(AppearanceManager.current, .system)
    }

    func testPersistsSelection() {
        AppearanceManager.current = .light
        XCTAssertEqual(AppearanceManager.current, .light)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppearanceManager.defaultsKey), "light")
    }

    func testFallsBackToSystemOnUnknownPersistedValue() {
        UserDefaults.standard.set("sepia", forKey: AppearanceManager.defaultsKey)
        XCTAssertEqual(AppearanceManager.current, .system)
    }

    func testStylesMapToUIKit() {
        XCTAssertEqual(AppAppearance.system.style, .unspecified)
        XCTAssertEqual(AppAppearance.light.style, .light)
        XCTAssertEqual(AppAppearance.dark.style, .dark)
    }

    // Exercises the real selection path the theme picker's alert action
    // invokes — persistence, window application, and the refreshed row value —
    // not just the storage seam.
    @MainActor
    func testSelectAppearancePersistsAppliesToWindowAndRefreshesRowValue() throws {
        let window = try XCTUnwrap(
            (UIApplication.shared.delegate as? AppDelegate)?.window,
            "test host should expose the app window"
        )

        let viewModel = SettingsViewModel()
        viewModel.update()

        viewModel.selectAppearance(.dark)

        XCTAssertEqual(AppearanceManager.current, .dark)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppearanceManager.defaultsKey), "dark")
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)

        let appearanceSection = try XCTUnwrap(viewModel.sections.first(where: { $0.title == "Appearance" }))
        let themeItem = try XCTUnwrap(appearanceSection.items.first(where: { $0.title == "Theme" }))
        XCTAssertEqual(themeItem.value as? String, "Dark")

        // Returning to System must clear the override so the OS appearance
        // drives the app again.
        viewModel.selectAppearance(.system)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(AppearanceManager.current, .system)
    }
}
