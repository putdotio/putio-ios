import XCTest

@testable import Putio

final class AppStoreReviewTests: XCTestCase {
  func testRatingLinkUsesTheConfiguredAppStoreIDOrTheLegacyListing() {
    let legacy = "https://apps.apple.com/app/id1260479699?action=write-review"
    for unusable in [nil, "", "  ", "$(PUTIO_APP_STORE_ID)", "id123", "12a4"] {
      XCTAssertEqual(
        PutioAppStoreReview.url(appID: unusable)?.absoluteString, legacy,
        String(describing: unusable))
    }
    XCTAssertEqual(
      PutioAppStoreReview.url(appID: " 6450000000 ")?.absoluteString,
      "https://apps.apple.com/app/id6450000000?action=write-review")
  }
}
