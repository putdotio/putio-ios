import Foundation
import PutioAPI

protocol HistoryViewModelDelegate: class {
    func stateChanged()
}

class HistoryViewModel {
    enum State {
        case idle
        case loading
        case empty
        case loaded
        case refreshing
        case failure(error: PutioAPIError)
    }

    enum ActionResult {
        case success
        case failure(error: PutioAPIError)
    }

    typealias ActionCompletion = ((_ result: ActionResult) -> Void)

    weak var delegate: HistoryViewModelDelegate?

    struct HistorySection {
        let title: String
        var events: [PutioHistoryEvent]
    }

    static let BASE_SECTIONS = [
        HistorySection(title: "Today", events: []),
        HistorySection(title: "Yesterday", events: []),
        HistorySection(title: "Last Week", events: []),
        HistorySection(title: "Ancient Times", events: [])
    ]

    var state: State = .idle {
        didSet {
            self.delegate?.stateChanged()
        }
    }

    var events: [PutioHistoryEvent] = [] {
        didSet {
            updateSections()

            if events.count == 0 {
                self.state = .empty
            } else {
                self.state = .loaded
            }
        }
    }

    var sections: [HistorySection] = []

    func updateSections() {
        guard events.count != 0 else {
            return sections = []
        }

        sections = HistoryViewModel.BASE_SECTIONS

        let eventsToDisplay = events.filter {
            switch $0.type {
            case .upload, .fileShared, .transferCompleted, .transferError, .fileFromRSSDeletedError, .rssFilterPaused, .transferFromRSSError, .transferCallbackError:
                return true
            default:
                return false
            }
        }

        let date: Date = Date()

        eventsToDisplay.forEach { (event) in
            let diff = (Calendar.current.dateComponents([.day], from: event.createdAt, to: date).day)!

            if diff == 0 {
                self.sections[0].events.append(event)
            } else if diff == 1 {
                self.sections[1].events.append(event)
            } else if diff < 8 {
                self.sections[2].events.append(event)
            } else {
                self.sections[3].events.append(event)
            }
        }

        sections = sections.filter {$0.events.count > 0}
    }

    private func fetchData() {
        api.getHistoryEvents { result in
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
        api.deleteHistoryEvent(eventID: event.id) { result in
            switch result {
            case .success:
                self.events = self.events.filter { $0.id != event.id }
                completion(.success)

            case .failure(let error):
                completion(.failure(error: error))
            }
        }
    }

    func removeAllEvents() {
        state = .loading

        api.clearHistoryEvents { result in
            switch result {
            case.success:
                self.events = []

            case .failure:
                self.state = .loaded
            }
        }
    }
}
