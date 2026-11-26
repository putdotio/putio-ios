import Foundation
import Synchronization

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// URLSession copies requests, so a session-specific header preserves fixture ownership.
final class TestURLProtocolRegistry<Fixture: AnyObject & Sendable>: Sendable {
  private struct Entry: @unchecked Sendable {
    weak var fixture: Fixture?
  }

  private struct State {
    var entries: [String: Entry] = [:]
    var latest: String?
  }

  private let state = Mutex(State())
  private let header = "X-Putio-Test-Fixture"

  func configure(_ configuration: URLSessionConfiguration, fixture: Fixture) {
    let identifier = UUID().uuidString
    state.withLock {
      $0.entries = $0.entries.filter { $0.value.fixture != nil }
      $0.entries[identifier] = Entry(fixture: fixture)
      $0.latest = identifier
    }
    configuration.httpAdditionalHeaders = [header: identifier]
  }

  func fixture(for request: URLRequest) -> Fixture? {
    let identifier = request.value(forHTTPHeaderField: header)
    return state.withLock { state in
      (identifier ?? state.latest).flatMap { state.entries[$0]?.fixture }
    }
  }
}
