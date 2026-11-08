import UIKit
import XCTest
@testable import Putio

final class FilesSelectionTests: XCTestCase {
    func testSelectAllSelectsEveryRowOfALargeListAndDeselectClearsThem() throws {
        let fileCount = 5_000
        FilesListStub.answerFilesList(with: fileCount, in: self)
        let folder = try pushLoadedFolder(onto: makeFilesNavigation(), listing: fileCount)

        folder.startEditing()
        folder.toggleSelectAll()

        XCTAssertEqual(folder.tableView.indexPathsForSelectedRows?.count, fileCount)
        XCTAssertTrue(folder.allSelected)

        folder.toggleSelectAll()

        XCTAssertEqual(folder.tableView.indexPathsForSelectedRows ?? [], [])
        XCTAssertFalse(folder.allSelected)
    }
}
