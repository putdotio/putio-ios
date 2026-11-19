import GoogleCast
import UIKit
import XCTest
@testable import Putio

final class CastResourcesTests: XCTestCase {
    override func setUp() {
        super.setUp()
        if !GCKCastContext.isSharedInstanceInitialized() {
            ChromecastManager.sharedInstance.setup()
        }
    }

    func testTheAppBundleCarriesTheCastResourceBundles() {
        for name in ["GoogleCastCoreResources", "GoogleCastUIResources"] {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "bundle"), name)
        }
    }

    func testTheExpandedCastControlsDrawTheirIcons() {
        let controls = GCKCastContext.sharedInstance().defaultExpandedMediaControlsViewController
        controls.loadViewIfNeeded()
        XCTAssertTrue(hasImage(in: controls.view))
    }

    private func hasImage(in view: UIView) -> Bool {
        if let button = view as? UIButton, button.currentImage != nil || button.imageView?.image != nil { return true }
        if let imageView = view as? UIImageView, imageView.image != nil { return true }
        return view.subviews.contains { hasImage(in: $0) }
    }
}
