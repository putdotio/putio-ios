import XCTest
@testable import Putio
import PutioSDK

private struct MockHistoryEvent: HistoryEventRepresentable {
    let historyEventID: Int
    let historyEventType: PutioHistoryEvent.EventType
    let historyEventCreatedAt: Date
}

final class HistoryViewModelTests: XCTestCase {
    func testApplyStateAndSummariesBucketsSupportedEventsByDateWindow() {
        let now = Date(timeIntervalSince1970: 1_712_000_000)
        let viewModel = HistoryViewModel()

        let summaries = viewModel.applyStateAndSummaries(for: [
            MockHistoryEvent(historyEventID: 1, historyEventType: .upload, historyEventCreatedAt: now),
            MockHistoryEvent(historyEventID: 2, historyEventType: .fileShared, historyEventCreatedAt: Calendar.current.date(byAdding: .day, value: -1, to: now)!),
            MockHistoryEvent(historyEventID: 3, historyEventType: .transferCompleted, historyEventCreatedAt: Calendar.current.date(byAdding: .day, value: -3, to: now)!),
            MockHistoryEvent(historyEventID: 4, historyEventType: .transferError, historyEventCreatedAt: Calendar.current.date(byAdding: .day, value: -10, to: now)!),
            MockHistoryEvent(historyEventID: 5, historyEventType: .voucher, historyEventCreatedAt: now)
        ], now: now)

        assertLoaded(viewModel.state)
        XCTAssertEqual(summaries.map(\.title), ["Today", "Yesterday", "Last Week", "Ancient Times"])
        XCTAssertEqual(summaries.map(\.eventIDs), [[1], [2], [3], [4]])
    }

    func testApplyStateAndSummariesWithNoEventsTransitionsToEmpty() {
        let viewModel = HistoryViewModel()

        let summaries = viewModel.applyStateAndSummaries(for: [], now: Date(timeIntervalSince1970: 1_712_000_000))

        assertEmpty(viewModel.state)
        XCTAssertTrue(summaries.isEmpty)
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
