import UIKit
import XCTest
@testable import Putio

final class FilesSelectionTests: XCTestCase {
    func testSelectAllButtonSelectsEveryRowOfALargeListAndDeselectAllClearsThem() throws {
        let fileCount = 5_000
        FilesListStub.answerFilesList(with: fileCount, in: self)
        let folder = try pushLoadedFolder(onto: makeFilesNavigation(), listing: fileCount)

        folder.startEditing()
        let button = try XCTUnwrap(folder.navigationItem.leftBarButtonItem)
        XCTAssertEqual(button.title, "Select All")

        try tap(button)

        XCTAssertEqual(folder.tableView.indexPathsForSelectedRows?.count, fileCount)
        XCTAssertEqual(folder.navigationItem.leftBarButtonItem?.title, "Deselect All")

        try tap(try XCTUnwrap(folder.navigationItem.leftBarButtonItem))

        XCTAssertEqual(folder.tableView.indexPathsForSelectedRows ?? [], [])
        XCTAssertEqual(folder.navigationItem.leftBarButtonItem?.title, "Select All")
    }
}
