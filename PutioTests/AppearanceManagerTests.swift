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
}
