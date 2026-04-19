import Foundation
import PutioSDK

protocol HistoryViewModelDelegate: AnyObject {
    func stateChanged()
}

protocol HistoryEventRepresentable {
    var historyEventID: Int { get }
    var historyEventType: PutioHistoryEvent.EventType { get }
    var historyEventCreatedAt: Date { get }
}

extension PutioHistoryEvent: HistoryEventRepresentable {
    var historyEventID: Int { id }
    var historyEventType: PutioHistoryEvent.EventType { type }
    var historyEventCreatedAt: Date { createdAt }
}

class HistoryViewModel {
    enum State {
        case idle
        case loading
        case empty
        case loaded
        case refreshing
        case failure(error: PutioSDKError)
    }

    enum ActionResult {
        case success
        case failure(error: PutioSDKError)
    }

    typealias ActionCompletion = ((_ result: ActionResult) -> Void)

    weak var delegate: HistoryViewModelDelegate?

    struct HistorySection {
        let title: String
        var events: [PutioHistoryEvent]
    }

    struct HistorySectionSummary: Equatable {
        let title: String
        var eventIDs: [Int]
    }

    static let BASE_SECTIONS = [
        HistorySection(title: NSLocalizedString("Today", comment: ""), events: []),
        HistorySection(title: NSLocalizedString("Yesterday", comment: ""), events: []),
        HistorySection(title: NSLocalizedString("Last Week", comment: ""), events: []),
        HistorySection(title: NSLocalizedString("Ancient Times", comment: ""), events: [])
    ]

    typealias FetchEventsRequest = (@escaping (Result<[PutioHistoryEvent], PutioSDKError>) -> Void) -> Void
    typealias RemoveEventRequest = (Int, @escaping (Result<Void, PutioSDKError>) -> Void) -> Void
    typealias ClearEventsRequest = (@escaping (Result<Void, PutioSDKError>) -> Void) -> Void

    private let fetchEventsRequest: FetchEventsRequest
    private let removeEventRequest: RemoveEventRequest
    private let clearEventsRequest: ClearEventsRequest

    var state: State = .idle {
        didSet {
            self.delegate?.stateChanged()
        }
    }

    var events: [PutioHistoryEvent] = [] {
        didSet {
            let summaries = applyStateAndSummaries(for: events)
            updateSections(using: summaries)
        }
    }

    var sections: [HistorySection] = []

    init(
        fetchEventsRequest: @escaping FetchEventsRequest = { completion in
            api.getHistoryEvents(completion: completion)
        },
        removeEventRequest: @escaping RemoveEventRequest = { eventID, completion in
            api.deleteHistoryEvent(eventID: eventID) { result in
                switch result {
                case .success:
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        },
        clearEventsRequest: @escaping ClearEventsRequest = { completion in
            api.clearHistoryEvents { result in
                switch result {
                case .success:
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    ) {
        self.fetchEventsRequest = fetchEventsRequest
        self.removeEventRequest = removeEventRequest
        self.clearEventsRequest = clearEventsRequest
    }

    static func summarizeSections(for events: [HistoryEventRepresentable], now: Date = Date()) -> [HistorySectionSummary] {
        guard !events.isEmpty else { return [] }

        var summaries = [
            HistorySectionSummary(title: NSLocalizedString("Today", comment: ""), eventIDs: []),
            HistorySectionSummary(title: NSLocalizedString("Yesterday", comment: ""), eventIDs: []),
            HistorySectionSummary(title: NSLocalizedString("Last Week", comment: ""), eventIDs: []),
            HistorySectionSummary(title: NSLocalizedString("Ancient Times", comment: ""), eventIDs: [])
        ]

        let eventsToDisplay = events.filter {
            switch $0.historyEventType {
            case .upload, .fileShared, .transferCompleted, .transferError, .fileFromRSSDeletedError, .rssFilterPaused, .transferFromRSSError, .transferCallbackError:
                return true
            default:
                return false
            }
        }

        eventsToDisplay.forEach { event in
            let diff = Calendar.current.dateComponents([.day], from: event.historyEventCreatedAt, to: now).day ?? 0

            if diff == 0 {
                summaries[0].eventIDs.append(event.historyEventID)
            } else if diff == 1 {
                summaries[1].eventIDs.append(event.historyEventID)
            } else if diff < 8 {
                summaries[2].eventIDs.append(event.historyEventID)
            } else {
                summaries[3].eventIDs.append(event.historyEventID)
            }
        }

        return summaries.filter { !$0.eventIDs.isEmpty }
    }

    @discardableResult
    func applyStateAndSummaries(for events: [HistoryEventRepresentable], now: Date = Date()) -> [HistorySectionSummary] {
        let summaries = HistoryViewModel.summarizeSections(for: events, now: now)

        if events.isEmpty {
            state = .empty
        } else {
            state = .loaded
        }

        return summaries
    }

    func updateSections(now: Date = Date()) {
        let summaries = applyStateAndSummaries(for: events, now: now)
        updateSections(using: summaries)
    }

    private func updateSections(using summaries: [HistorySectionSummary]) {
        guard events.count != 0 else {
            return sections = []
        }

        let eventLookup = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })

        sections = summaries.compactMap { summary in
            let sectionEvents = summary.eventIDs.compactMap { eventLookup[$0] }
            guard !sectionEvents.isEmpty else { return nil }
            return HistorySection(title: summary.title, events: sectionEvents)
        }
    }

    private func fetchData() {
        fetchEventsRequest { result in
            switch result {
            case .success(let events):
                self.events = events

            case .failure(let error):
                self.state = .failure(error: error)
            }
        }
    }

    func fetchEvents() {
        state = .loading
        fetchData()
    }

    func refetchEvents() {
        state = .refreshing
        fetchData()
    }

    func removeEvent(_ event: PutioHistoryEvent, completion: @escaping ActionCompletion) {
        removeEvent(eventID: event.id, completion: completion)
    }

    func removeEvent(eventID: Int, completion: @escaping ActionCompletion) {
        removeEventRequest(eventID) { result in
            switch result {
            case .success:
                self.events = self.events.filter { $0.id != eventID }
                completion(.success)

            case .failure(let error):
                completion(.failure(error: error))
            }
        }
    }

    func removeAllEvents() {
        state = .loading

        clearEventsRequest { result in
            switch result {
            case.success:
                self.events = []

            case .failure:
                self.state = .loaded
            }
        }
    }
}
