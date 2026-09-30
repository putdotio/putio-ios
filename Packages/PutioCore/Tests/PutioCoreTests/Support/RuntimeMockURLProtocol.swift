import Foundation
import Synchronization

// URLProtocol supports asynchronous client callbacks. Gated tests retain each
// loader behind a Mutex and release it exactly once.
final class RuntimeMockURLProtocol: URLProtocol, @unchecked Sendable {
  fileprivate struct Fixture: Sendable {
    let statusCode: Int
    let body: String
  }

  fileprivate final class GatedResponse: Sendable {
    private let fixture: Fixture
    private let loader: RuntimeMockURLProtocol
    private let released = Mutex(false)

    init(loader: RuntimeMockURLProtocol, fixture: Fixture) {
      self.fixture = fixture
      self.loader = loader
    }

    func release() {
      let shouldRespond = released.withLock { released in
        guard !released else { return false }
        released = true
        return true
      }
      guard shouldRespond else { return }
      loader.respond(with: fixture)
    }
  }

  private enum Action: Sendable {
    case fixture(Fixture)
    case gatedFixture(Fixture)
    case networkFailure
    case nonHTTPResponse
    case suspend
  }

  fileprivate struct State {
    var fixtures: [String: Fixture] = [:]
    var networkFailureRoutes: Set<String> = []
    var nonHTTPRoutes: Set<String> = []
    var suspendedRoutes: Set<String> = []
    var gatedRoutes: Set<String> = []
    var gatedResponses: [String: GatedResponse] = [:]
    var requests: [URLRequest] = []
  }

  static let registry = TestURLProtocolRegistry<Fixtures>()

  final class Fixtures: Sendable {
    fileprivate let state = Mutex(State())

    func reset() {
      state.withLock { $0 = State() }
    }

    func setFixture(_ body: String, statusCode: Int = 200, for route: String) {
      state.withLock { $0.fixtures[route] = Fixture(statusCode: statusCode, body: body) }
    }

    func setNetworkFailure(_ enabled: Bool, for route: String) {
      state.withLock {
        if enabled {
          $0.networkFailureRoutes.insert(route)
        } else {
          $0.networkFailureRoutes.remove(route)
        }
      }
    }

    func setNonHTTPResponse(_ enabled: Bool, for route: String) {
      state.withLock {
        if enabled {
          $0.nonHTTPRoutes.insert(route)
        } else {
          $0.nonHTTPRoutes.remove(route)
        }
      }
    }

    func suspend(_ route: String) {
      state.withLock { _ = $0.suspendedRoutes.insert(route) }
    }

    func gateFixture(_ body: String, statusCode: Int = 200, for route: String) {
      state.withLock {
        $0.fixtures[route] = Fixture(statusCode: statusCode, body: body)
        $0.gatedRoutes.insert(route)
      }
    }

    func releaseFixture(for route: String) {
      let response = state.withLock { state in
        state.gatedRoutes.remove(route)
        return state.gatedResponses.removeValue(forKey: route)
      }
      response?.release()
    }

    func capturedRequests() -> [URLRequest] {
      state.withLock { $0.requests }
    }

  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    guard let fixtures = Self.registry.fixture(for: request) else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let route = "\(request.httpMethod ?? "GET") \(url.path)"
    let capturedRequest = request
    let action = fixtures.state.withLock { state -> Action in
      if state.suspendedRoutes.contains(route) {
        state.requests.append(capturedRequest)
        return .suspend
      }
      if state.networkFailureRoutes.contains(route) {
        state.requests.append(capturedRequest)
        return .networkFailure
      }
      if state.nonHTTPRoutes.contains(route) {
        state.requests.append(capturedRequest)
        return .nonHTTPResponse
      }
      let fixture =
        state.fixtures[route]
        ?? Fixture(
          statusCode: 404,
          body: #"{"status":"ERROR","status_code":404,"error_type":"FIXTURE_NOT_FOUND"}"#
        )
      if state.gatedRoutes.remove(route) != nil {
        return .gatedFixture(fixture)
      }
      state.requests.append(capturedRequest)
      return .fixture(fixture)
    }

    switch action {
    case .fixture(let fixture):
      respond(with: fixture)
    case .gatedFixture(let fixture):
      let response = GatedResponse(loader: self, fixture: fixture)
      fixtures.state.withLock { state in
        state.gatedResponses[route] = response
        state.requests.append(capturedRequest)
      }
      return
    case .networkFailure:
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    case .nonHTTPResponse:
      let response = URLResponse(
        url: url,
        mimeType: "application/json",
        expectedContentLength: 0,
        textEncodingName: "utf-8"
      )
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
    case .suspend:
      break
    }
  }

  override func stopLoading() {}

  private func respond(with fixture: Fixture) {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: fixture.statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(fixture.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}
