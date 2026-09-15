import Foundation
import Synchronization

// URLSession copies requests, so a session-specific header preserves fixture ownership.
final class TestURLProtocolRegistry<Fixture: AnyObject & Sendable>: Sendable {
  private struct Entry: @unchecked Sendable {
    weak var fixture: Fixture?
  }

  private let entries = Mutex<[String: Entry]>([:])
  private let header = "X-Putio-Test-Fixture"

  func configure(_ configuration: URLSessionConfiguration, fixture: Fixture) {
    let identifier = UUID().uuidString
    entries.withLock {
      $0 = $0.filter { $0.value.fixture != nil }
      $0[identifier] = Entry(fixture: fixture)
    }
    configuration.httpAdditionalHeaders = [header: identifier]
  }

  func fixture(for request: URLRequest) -> Fixture? {
    guard let identifier = request.value(forHTTPHeaderField: header) else { return nil }
    return entries.withLock { $0[identifier]?.fixture }
  }
}
