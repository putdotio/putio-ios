import Sentry
import XCTest
@testable import Putio

final class SentryTelemetryTests: XCTestCase {
    func testOnlyAllowlistedFieldsLeaveTheDevice() throws {
        let title = "Synthetic Feature Title"
        let fileName = "Synthetic.Feature.Title.2001.mkv"
        let host = "media.example.invalid"
        let token = "synthetic-token-5f1c9e"
        let leak = "\(title) /Documents/\(fileName) https://\(host)/hls/master.m3u8?oauth_token=\(token)"

        let event = Event(level: .error)
        event.message = SentryMessage(formatted: leak)
        event.logger = leak
        event.serverName = leak
        event.transaction = leak
        event.type = leak
        event.modules = [leak: leak]
        event.extra = [leak: leak]
        event.fingerprint = [leak]
        event.releaseName = "io.put.synthetic@1.0+1"
        event.tags = ["category": "downloads_observation", leak: leak]
        event.context = ["os": ["name": "iOS"], "culture": [leak: leak], "user info": [leak: leak], "response": [leak: leak]]
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
        event.exceptions = [{
            let exception = Exception(value: leak, type: "NSURLErrorDomain")
            exception.module = leak
            exception.mechanism = Mechanism(type: "NSError")
            exception.mechanism?.desc = leak
            exception.mechanism?.data = [leak: leak]
            exception.mechanism?.helpLink = leak
            exception.mechanism?.meta = MechanismContext()
            exception.mechanism?.meta?.error = SentryNSError(domain: "NSURLErrorDomain", code: -1009)
            return exception
        }()]
        let breadcrumb = Breadcrumb(level: .info, category: leak)
        breadcrumb.type = leak
        breadcrumb.origin = leak
        breadcrumb.message = leak
        breadcrumb.data = [leak: leak]
        event.breadcrumbs = [breadcrumb]
        // Watchdog terminations carry breadcrumbs read back from disk here.
        event.setValue([breadcrumb.serialize()], forKey: "serializedBreadcrumbs")

        let options = SentryTelemetry.options(dsn: "https://synthetickey@sentry.example.invalid/1")
        let sent = try XCTUnwrap(options.beforeSend?(event))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: sent.serialize()), as: UTF8.self)

        for leaked in [title, fileName, host, token] {
            XCTAssertFalse(json.contains(leaked), "\(leaked) left the device: \(json)")
        }
        XCTAssertEqual(sent.tags, ["category": "downloads_observation"])
        XCTAssertEqual(sent.exceptions?.first?.type, "NSURLErrorDomain")
        XCTAssertEqual(sent.exceptions?.first?.value, "downloads_observation")
        XCTAssertEqual(sent.exceptions?.first?.mechanism?.meta?.error?.code, -1009)
        XCTAssertEqual(sent.context?["os"]?["name"] as? String, "iOS")
        XCTAssertEqual(sent.user?.userId, "synthetic-installation")
        XCTAssertEqual(sent.releaseName, "io.put.synthetic@1.0+1")
    }
}
