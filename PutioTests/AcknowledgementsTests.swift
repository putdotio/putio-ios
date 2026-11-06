import XCTest
@testable import Putio

final class AcknowledgementsTests: XCTestCase {
    func testTheAppBundlesALicenseForEveryShippedLibrary() {
        let acknowledgements = Acknowledgement.bundled()
        let titles = Set(acknowledgements.map(\.title))

        XCTAssertTrue(titles.isSuperset(of: ["Google Cast SDK", "Intercom", "PostHog", "RealmSwift", "Sentry", "StatefulViewController"]), "\(titles)")
        XCTAssertFalse(acknowledgements.contains { $0.license.isEmpty })
    }
}
