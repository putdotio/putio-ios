import Sentry
import XCTest

@testable import Putio

final class SentryTelemetryTests: XCTestCase {
  private let configuration = SentryConfiguration(info: [
    "PUTIO_SENTRY_ENABLED": "YES", "PUTIO_SENTRY_DSN": "https://synthetickey@relay.put.io/1",
  ])

  func testOnlyAllowlistedFieldsLeaveTheDevice() throws {
    let title = "Synthetic Feature Title"
    let fileName = "Synthetic.Feature.Title.2001.mkv"
    let host = "media.example.invalid"
    let token = "synthetic-token-5f1c9e"
    let leak =
      "\(title) /Documents/\(fileName) https://\(host)/hls/master.m3u8?oauth_token=\(token)"

    let event = Event(level: .error)
    event.message = SentryMessage(formatted: leak)
    event.logger = leak
    event.serverName = leak
    event.transaction = leak
    event.type = leak
    event.modules = [leak: leak]
    event.extra = [leak: leak]
    event.fingerprint = [leak]
    event.tags = [leak: leak]
    event.releaseName = "io.put.synthetic@1.0+1"
    event.context = [
      "os": ["name": "iOS"], "culture": [leak: leak], "user info": [leak: leak],
      "response": [leak: leak],
    ]
    event.user = {
      let user = Sentry.User(userId: "synthetic-installation")
      user.email = leak
      user.username = leak
      user.name = leak
      user.ipAddress = leak
      user.data = [leak: leak]
      return user
    }()
    event.request = {
      let request = SentryRequest()
      request.method = leak
      request.url = leak
      request.queryString = leak
      request.fragment = leak
      request.headers = [leak: leak]
      request.cookies = leak
      return request
    }()
    event.exceptions = [
      {
        let exception = Exception(value: leak, type: "NSURLErrorDomain")
        exception.module = leak
        exception.mechanism = Mechanism(type: "NSError")
        exception.mechanism?.desc = leak
        exception.mechanism?.data = [leak: leak]
        exception.mechanism?.helpLink = leak
        exception.mechanism?.meta = MechanismContext()
        exception.mechanism?.meta?.error = SentryNSError(domain: "NSURLErrorDomain", code: -1009)
        return exception
      }()
    ]
    let breadcrumb = Breadcrumb(level: .info, category: leak)
    breadcrumb.type = leak
    breadcrumb.origin = leak
    breadcrumb.message = leak
    breadcrumb.data = [leak: leak]
    event.breadcrumbs = [breadcrumb]
    // Watchdog terminations carry breadcrumbs read back from disk here.
    event.setValue([breadcrumb.serialize()], forKey: "serializedBreadcrumbs")

    allowCapture(true)
    let options = SentryTelemetry.options(try XCTUnwrap(configuration))
    let sent = try XCTUnwrap(options.beforeSend?(event))
    let json = String(
      decoding: try JSONSerialization.data(withJSONObject: sent.serialize()), as: UTF8.self)

    for leaked in [title, fileName, host, token] {
      XCTAssertFalse(json.contains(leaked), "\(leaked) left the device: \(json)")
    }
    XCTAssertEqual(sent.exceptions?.first?.type, "NSURLErrorDomain")
    XCTAssertEqual(sent.exceptions?.first?.mechanism?.meta?.error?.code, -1009)
    XCTAssertEqual(sent.context?["os"]?["name"] as? String, "iOS")
    XCTAssertEqual(sent.user?.userId, "synthetic-installation")
    XCTAssertEqual(sent.releaseName, "io.put.synthetic@1.0+1")
  }

  func testSwitchingOffSendsNothingRecordedBefore() throws {
    let configuration = try XCTUnwrap(self.configuration)
    let options = SentryTelemetry.options(configuration)
    XCTAssertEqual(options.cacheDirectoryPath, SentryTelemetry.cacheDirectory.path)
    let pending = SentryTelemetry.cacheDirectory.appending(path: "envelopes/pending")
    try FileManager.default.createDirectory(
      at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("synthetic".utf8).write(to: pending)
    let gate = try XCTUnwrap(options.urlSessionDelegate as? URLSessionTaskDelegate)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let envelope = try XCTUnwrap(URL(string: "https://relay.example.invalid/api/1/envelope/"))
    func upload() -> URLSessionTask {
      let task = session.dataTask(with: envelope)
      gate.urlSession?(session, didCreateTask: task)
      return task
    }

    allowCapture(true)
    XCTAssertNotNil(options.beforeSend?(Event(level: .error)))
    XCTAssertEqual(upload().state, .suspended)

    SentryTelemetry.setCapturing(false, configuration: configuration)

    XCTAssertNil(options.beforeSend?(Event(level: .error)))
    XCTAssertNotEqual(upload().state, .suspended, "an upload left while diagnostics were off")
    XCTAssertFalse(FileManager.default.fileExists(atPath: SentryTelemetry.cacheDirectory.path))
  }

  private func allowCapture(_ enabled: Bool) {
    let previous = SentryTelemetry.isCapturing
    SentryTelemetry.isCapturing = enabled
    addTeardownBlock { SentryTelemetry.isCapturing = previous }
  }
}
