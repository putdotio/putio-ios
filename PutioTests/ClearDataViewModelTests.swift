import XCTest
@testable import Putio
import PutioSDK

final class ClearDataViewModelTests: XCTestCase {
    private var sentOptions: [PutioAccountClearOptions] = []

    override func setUp() {
        super.setUp()
        sentOptions = []
    }

    func testCancelSendsNoRequest() throws {
        let viewModel = try makeViewModel(selecting: ["files"])
        var prompts = 0

        viewModel.cleanUp(
            confirm: { _, answer in
                prompts += 1
                answer(false)
            },
            completion: { _ in XCTFail("Cancel must not complete a clear") }
        )

        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(sentOptions.isEmpty)
        XCTAssertTrue(viewModel.canClear, "Cancel should leave Clear available for another try")
    }

    func testConfirmSendsTheSelectedCategoriesOnce() throws {
        let viewModel = try makeViewModel(selecting: ["files", "history"])
        var results: [ClearDataViewModel.ActionResult] = []

        viewModel.cleanUp(confirm: { _, answer in answer(true) }, completion: { results.append($0) })

        XCTAssertEqual(sentOptions.count, 1)
        XCTAssertEqual(sentOptions.first.map(fields), [
            "files": true,
            "finishedTransfers": false,
            "activeTransfers": false,
            "rssFeeds": false,
            "rssLogs": false,
            "history": true,
            "trash": false,
            "friends": false
        ])
        XCTAssertEqual(results.count, 1)
        guard case .success = results.first else {
            return XCTFail("Expected success, got \(String(describing: results.first))")
        }
    }

    func testNothingSelectedNeitherPromptsNorSends() throws {
        let viewModel = try makeViewModel(selecting: [])

        viewModel.cleanUp(
            confirm: { _, _ in XCTFail("Nothing selected must not prompt") },
            completion: { _ in XCTFail("Nothing selected must not complete a clear") }
        )

        XCTAssertFalse(viewModel.canClear)
        XCTAssertTrue(sentOptions.isEmpty)
    }

    func testConfirmationNamesTheSelectedTitles() throws {
        let viewModel = try makeViewModel(selecting: ["trash", "files", "rss_feeds"])
        var message: String?

        viewModel.cleanUp(confirm: { prompt, _ in message = prompt }, completion: { _ in })

        // The list punctuation follows the device region, so join the titles the same way.
        let titles = ListFormatter.localizedString(byJoining: ["Files", "RSS feeds", "Trash"])
        XCTAssertEqual(message, "This permanently deletes \(titles) from your put.io account. It can't be undone.")
    }

    func testEverySDKOptionHasATitle() {
        let viewModel = ClearDataViewModel(clearRequest: { _, _ in })

        XCTAssertEqual(viewModel.keys.map(viewModel.title(for:)), [
            "Files",
            "Finished transfers",
            "Active transfers",
            "RSS feeds",
            "RSS logs",
            "History",
            "Trash",
            "Friends"
        ])
    }

    private func makeViewModel(selecting keys: [String]) throws -> ClearDataViewModel {
        let ok = try JSONDecoder().decode(PutioOKResponse.self, from: Data(#"{"status":"OK"}"#.utf8))
        let viewModel = ClearDataViewModel(clearRequest: { options, completion in
            self.sentOptions.append(options)
            completion(.success(ok))
        })
        keys.forEach(viewModel.toggleOption(key:))
        return viewModel
    }

    private func fields(_ options: PutioAccountClearOptions) -> [String: Bool] {
        [
            "files": options.files,
            "finishedTransfers": options.finishedTransfers,
            "activeTransfers": options.activeTransfers,
            "rssFeeds": options.rssFeeds,
            "rssLogs": options.rssLogs,
            "history": options.history,
            "trash": options.trash,
            "friends": options.friends
        ]
    }
}
