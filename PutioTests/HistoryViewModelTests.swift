import XCTest
import UIKit
@testable import Putio
import PutioSDK

private struct MockHistoryEvent: HistoryEventRepresentable {
    let historyEventID: Int
    let historyEventType: PutioHistoryEvent.EventType
    let historyEventCreatedAt: Date
}

final class HistoryViewModelTests: XCTestCase {
    func testSummarizeSectionsBucketsSupportedEventsByDateWindow() {
        let now = Date(timeIntervalSince1970: 1_712_000_000)

        let summaries = HistoryViewModel.summarizeSections(for: [
            MockHistoryEvent(historyEventID: 1, historyEventType: .upload, historyEventCreatedAt: now),
            MockHistoryEvent(historyEventID: 2, historyEventType: .fileShared, historyEventCreatedAt: Calendar.current.date(byAdding: .day, value: -1, to: now)!),
            MockHistoryEvent(historyEventID: 3, historyEventType: .transferCompleted, historyEventCreatedAt: Calendar.current.date(byAdding: .day, value: -3, to: now)!),
            MockHistoryEvent(historyEventID: 4, historyEventType: .transferError, historyEventCreatedAt: Calendar.current.date(byAdding: .day, value: -10, to: now)!),
            MockHistoryEvent(historyEventID: 5, historyEventType: .voucher, historyEventCreatedAt: now)
        ], now: now)

        XCTAssertEqual(summaries.map(\.title), ["Today", "Yesterday", "Last Week", "Ancient Times"])
        XCTAssertEqual(summaries.map(\.eventIDs), [[1], [2], [3], [4]])
    }

    func testSummarizeSectionsWithNoEventsIsEmpty() {
        let summaries = HistoryViewModel.summarizeSections(for: [], now: Date(timeIntervalSince1970: 1_712_000_000))

        XCTAssertTrue(summaries.isEmpty)
    }

    func testEmptyFetchTransitionsToEmptyAndClearsSections() {
        var fetchCompletion: ((Result<[PutioHistoryEvent], PutioSDKError>) -> Void)?
        let viewModel = HistoryViewModel(fetchEventsRequest: { completion in fetchCompletion = completion })

        viewModel.fetchEvents()
        fetchCompletion?(.success([]))

        assertEmpty(viewModel.state)
        XCTAssertTrue(viewModel.sections.isEmpty)
    }

    func testRemoveEventByIDUsesInjectedRequest() {
        let completionExpectation = expectation(description: "remove event completion")
        var receivedEventID: Int?

        let viewModel = HistoryViewModel(
            removeEventRequest: { eventID, completion in
                receivedEventID = eventID
                completion(.success(()))
            }
        )

        viewModel.removeEvent(eventID: 42) { result in
            switch result {
            case .success:
                completionExpectation.fulfill()
            case .failure(let error):
                XCTFail("Expected success, got \(error.message)")
            }
        }

        wait(for: [completionExpectation], timeout: 1.0)
        XCTAssertEqual(receivedEventID, 42)
        assertEmpty(viewModel.state)
    }

    func testRemoveAllEventsSuccessTransitionsToEmpty() {
        let viewModel = HistoryViewModel(
            clearEventsRequest: { completion in
                completion(.success(()))
            }
        )

        viewModel.removeAllEvents()

        assertEmpty(viewModel.state)
    }

    private func assertLoaded(_ state: HistoryViewModel.State, file: StaticString = #filePath, line: UInt = #line) {
        guard case .loaded = state else {
            return XCTFail("Expected loaded state", file: file, line: line)
        }
    }

    private func assertEmpty(_ state: HistoryViewModel.State, file: StaticString = #filePath, line: UInt = #line) {
        guard case .empty = state else {
            return XCTFail("Expected empty state", file: file, line: line)
        }
    }
}

// Mirrors HistoryViewController's wiring: the data source reads viewModel.sections
// and the delegate reloads the table synchronously when state becomes .loaded.
private final class HistoryTableHarness: NSObject, UITableViewDataSource, HistoryViewModelDelegate {
    let viewModel: HistoryViewModel
    let tableView = UITableView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), style: .plain)
    private(set) var sectionCountsSeenAtLoaded: [Int] = []

    init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
        super.init()
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        viewModel.delegate = self
    }

    func stateChanged() {
        if case .loaded = viewModel.state {
            sectionCountsSeenAtLoaded.append(viewModel.sections.count)
            tableView.reloadData()
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int { viewModel.sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { viewModel.sections[section].events.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
    }
}

// Regression coverage for the first-load-renders-empty bug: sections must be
// rebuilt before .loaded is published, otherwise the table renders one fetch behind.
@MainActor
final class HistoryFirstLoadRenderTests: XCTestCase {
    private func makeEvent(id: Int) throws -> PutioHistoryEvent {
        let json = #"{"id": \#(id), "user_id": 1, "type": "upload", "created_at": "2026-07-21T09:00:00Z"}"#
        return try JSONDecoder().decode(PutioHistoryEvent.self, from: Data(json.utf8))
    }

    private func makeFixture() -> (viewModel: HistoryViewModel, harness: HistoryTableHarness, complete: (Result<[PutioHistoryEvent], PutioSDKError>) -> Void) {
        var fetchCompletion: ((Result<[PutioHistoryEvent], PutioSDKError>) -> Void)?
        let viewModel = HistoryViewModel(fetchEventsRequest: { completion in fetchCompletion = completion })
        let harness = HistoryTableHarness(viewModel: viewModel)
        return (viewModel, harness, { result in fetchCompletion?(result) })
    }

    func testSectionsArePopulatedWhenLoadedStateFires() throws {
        let fixture = makeFixture()

        fixture.viewModel.fetchEvents()
        fixture.complete(.success([try makeEvent(id: 1)]))

        XCTAssertEqual(fixture.harness.sectionCountsSeenAtLoaded, [1])
    }

    func testFirstFetchRendersRowsInTable() throws {
        let fixture = makeFixture()

        // Mirror the real app: the table is on screen and laid out before the fetch
        // completes. An off-window table defers its first row-count build and would
        // mask this regression.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        window.addSubview(fixture.harness.tableView)
        window.makeKeyAndVisible()
        fixture.harness.tableView.layoutIfNeeded()

        fixture.viewModel.fetchEvents()
        fixture.complete(.success([try makeEvent(id: 1)]))
        fixture.harness.tableView.layoutIfNeeded()

        XCTAssertEqual(fixture.harness.tableView.numberOfSections, 1)
        XCTAssertEqual(fixture.harness.tableView.numberOfRows(inSection: 0), 1)
    }

    func testRefreshRendersLatestFetch() throws {
        let fixture = makeFixture()

        fixture.viewModel.fetchEvents()
        fixture.complete(.success([try makeEvent(id: 1)]))
        fixture.harness.tableView.layoutIfNeeded()
        XCTAssertEqual(fixture.harness.tableView.numberOfSections, 1)

        fixture.viewModel.refetchEvents()
        fixture.complete(.success([try makeEvent(id: 1), try makeEvent(id: 2)]))
        fixture.harness.tableView.layoutIfNeeded()

        XCTAssertEqual(fixture.harness.tableView.numberOfRows(inSection: 0), 2)
    }
}
