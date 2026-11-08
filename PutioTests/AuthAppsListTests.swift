import XCTest
@testable import Putio
import PutioSDK

final class AuthAppsListTests: XCTestCase {
    func testRemovingGrantAfterAnEarlierRevokeRemovesThatGrantAtItsCurrentIndex() throws {
        let a = try grant(id: 1, name: "A")
        let b = try grant(id: 2, name: "B")
        let c = try grant(id: 3, name: "C")
        let afterA = AuthAppsList.removingGrant(id: a.id, from: [a, b, c])

        let afterB = AuthAppsList.removingGrant(id: b.id, from: afterA.apps)

        XCTAssertEqual(afterB.apps.map(\.id), [c.id])
        XCTAssertEqual(afterB.removedIndex, 0)
    }

    func testRemovingGrantNoLongerInTheListLeavesItUnchanged() throws {
        let a = try grant(id: 1, name: "A")
        let b = try grant(id: 2, name: "B")
        let c = try grant(id: 3, name: "C")

        let result = AuthAppsList.removingGrant(id: a.id, from: [b, c])

        XCTAssertEqual(result.apps.map(\.id), [b.id, c.id])
        XCTAssertNil(result.removedIndex)
    }

    private func grant(id: Int, name: String) throws -> PutioOAuthGrant {
        let json = #"{"id":\#(id),"name":"\#(name)","description":""}"#
        return try JSONDecoder().decode(PutioOAuthGrant.self, from: Data(json.utf8))
    }
}
