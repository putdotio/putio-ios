import UIKit
import XCTest
@testable import Putio

final class FilesViewControllerReleaseTests: XCTestCase {
    func testPoppedFolderIsReleasedOnceItsWorkSettles() throws {
        FilesListStub.answerFilesList(with: 3, in: self)
        let navigationController = try makeFilesNavigation()

        weak var released: FilesViewController?
        try autoreleasepool {
            released = try pushLoadedFolder(onto: navigationController, listing: 3)
            navigationController.popViewController(animated: false)
            navigationController.view.layoutIfNeeded()
        }

        let isReleased = expectation(for: NSPredicate { _, _ in released == nil }, evaluatedWith: nil)
        wait(for: [isReleased], timeout: 5)
    }
}
