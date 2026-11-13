import GoogleCast
import os
import PutioSDK
import RealmSwift
import UIKit
import XCTest
@testable import Putio

final class CastStubReceiverTests: XCTestCase {
    private let receiver = StubCastReceiver()
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    private let host = CastHostViewController()

    override func setUpWithError() throws {
        try super.setUpWithError()
        if !GCKCastContext.isSharedInstanceInitialized() {
            ChromecastManager.sharedInstance.setup()
        }
        try seedRealm(rememberVideoTime: true)
        CastAPIStub.install(in: self)

        GCKCastContext.sharedInstance().register(receiver)
        GCKCastContext.sharedInstance().discoveryManager.startDiscovery()

        window.rootViewController = host
        window.makeKeyAndVisible()
    }

    override func tearDown() {
        let sessionManager = GCKCastContext.sharedInstance().sessionManager
        if sessionManager.hasConnectedSession() {
            sessionManager.endSessionAndStopCasting(true)
        }
        GCKCastContext.sharedInstance().unregisterDeviceProvider(forCategory: kGCKCastDeviceCategory)
        ChromecastManager.sharedInstance.timer?.invalidate()
        host.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        super.tearDown()
    }

    func testTheCastButtonFindsTheReceiverAndDrawsItsIcon() {
        let discoveryManager = GCKCastContext.sharedInstance().discoveryManager
        waitUntil("the stub receiver is discovered") { discoveryManager.device(withUniqueID: self.receiver.device.uniqueID) != nil }

        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        host.view.addSubview(button)
        waitUntil("the Cast button shows an icon") { !button.isHidden && self.hasImage(in: button) }
        XCTAssertNotEqual(GCKCastContext.sharedInstance().castState, .noDevicesAvailable)
    }

    func testACastLoadsPlaysPausesSeeksAndEndsBackOnThePhone() throws {
        let manager = ChromecastManager.sharedInstance
        let sessionManager = GCKCastContext.sharedInstance().sessionManager
        XCTAssertTrue(sessionManager.startSession(with: receiver.device))
        waitUntil("the stub session starts") { manager.isActive() }
        let client = try XCTUnwrap(receiver.session?.client)

        let video = try CastAPIStub.videoFile()
        host.presentFile(video)
        waitUntil("the receiver gets a load") { client.loadedMedia != nil }

        XCTAssertEqual(client.commands, [.load(contentID: "https://api.put.io/v2/files/42/mp4/stream?oauth_token=e2e-token", autoplay: true, position: 125)])
        XCTAssertEqual(client.loadedMedia?.contentType, "video/mp4")
        XCTAssertEqual(client.loadedMedia?.streamDuration, 300)
        XCTAssertEqual(client.loadedMedia?.metadata?.string(forKey: kGCKMetadataKeyTitle), "Big Buck Bunny.mp4")
        XCTAssertEqual(client.loadedMedia?.mediaTracks?.map(\.languageCode), ["en"])

        client.finishLoading()
        waitUntil("the expanded controls draw their icons") {
            guard let expanded = self.host.presentedViewController as? GCKUIExpandedMediaControlsViewController else { return false }
            return self.hasImage(in: expanded.view)
        }

        let controller = GCKUIMediaController()
        let pause = UIButton(type: .custom)
        let play = UIButton(type: .custom)
        let forward = UIButton(type: .custom)
        controller.pauseButton = pause
        controller.playButton = play
        controller.forward30SecondsButton = forward
        waitUntil("the media controller binds the session") { controller.mediaLoaded }

        pause.sendActions(for: .touchUpInside)
        waitUntil("the receiver pauses") { controller.lastKnownPlayerState == .paused }
        play.sendActions(for: .touchUpInside)
        waitUntil("the receiver plays") { controller.lastKnownPlayerState == .playing }
        forward.sendActions(for: .touchUpInside)
        waitUntil("the receiver seeks") { client.approximateStreamPosition() == 155 }
        XCTAssertEqual(Array(client.commands.dropFirst()), [.pause, .play, .seek(interval: 30, relative: true)])

        manager.timer?.fire()
        waitUntil("the cast position is saved") { CastAPIStub.savedStartFrom == [155] }

        XCTAssertTrue(sessionManager.endSessionAndStopCasting(true))
        waitUntil("the session ends") { !manager.isActive() }
        XCTAssertEqual(receiver.session?.endAction, .stopCasting)
        XCTAssertEqual(manager.timer?.isValid, false)

        host.presentedViewController?.dismiss(animated: false)
        waitUntil("the expanded controls close") { self.host.presentedViewController == nil }
        host.presentFile(video)
        waitUntil("the video plays on the phone") { self.host.presentedViewController is VideoPlayerViewController }
        XCTAssertEqual(client.commands.count, 4)
    }

    private func seedRealm(rememberVideoTime: Bool) throws {
        let previous = Realm.Configuration.defaultConfiguration
        let configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        Realm.Configuration.defaultConfiguration = configuration
        let realm = try XCTUnwrap(PutioRealm.open(context: "CastStubReceiverTests.realm", configuration: configuration))
        let user = Putio.User()
        let settings = UserSettings()
        settings.rememberVideoTime = rememberVideoTime
        user.settings = settings
        XCTAssertTrue(PutioRealm.write(realm, context: "CastStubReceiverTests.user") { realm.add(user) })
        addTeardownBlock {
            realm.invalidate()
            Realm.Configuration.defaultConfiguration = previous
        }
    }

    private func hasImage(in view: UIView) -> Bool {
        if let button = view as? UIButton, button.currentImage != nil || button.imageView?.image != nil { return true }
        if let imageView = view as? UIImageView, imageView.image != nil || imageView.animationImages?.isEmpty == false { return true }
        return view.subviews.contains { hasImage(in: $0) }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) {
        let met = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        met.expectationDescription = description
        wait(for: [met], timeout: timeout)
    }
}

private final class CastHostViewController: UIViewController, FilePresenter {}

private final class CastAPIStub: URLProtocol {
    private static let saved = OSAllocatedUnfairLock(initialState: [Int]())

    static var savedStartFrom: [Int] { saved.withLock { $0 } }

    static func install(in testCase: XCTestCase) {
        saved.withLock { $0 = [] }
        URLProtocol.registerClass(CastAPIStub.self)
        testCase.addTeardownBlock { URLProtocol.unregisterClass(CastAPIStub.self) }
    }

    static func videoFile() throws -> PutioFile {
        try JSONDecoder().decode(PutioFile.self, from: Data(video.utf8))
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.put.io"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "/v2/files/list"):
            respond(url: url, body: #"{"parent": \#(Self.video), "files": [], "cursor": null, "total": 0}"#)
        case ("GET", "/v2/files/42/subtitles"):
            respond(url: url, body: Self.subtitles)
        case ("POST", "/v2/files/42/start-from/set"):
            if let time = Self.time(in: request) {
                Self.saved.withLock { $0.append(time) }
            }
            respond(url: url, body: #"{"status": "OK"}"#)
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    override func stopLoading() {}

    private func respond(url: URL, body: String) {
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func time(in request: URLRequest) -> Int? {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            body = data
        }
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json["time"] as? Int
    }

    private static let video = """
    {
      "id": 42,
      "name": "Big Buck Bunny.mp4",
      "icon": "video",
      "parent_id": 0,
      "size": 276205568,
      "created_at": "2026-04-24T10:00:00Z",
      "updated_at": "2026-04-24T10:00:00Z",
      "file_type": "VIDEO",
      "is_shared": false,
      "video_metadata": {"height": 720, "width": 1280, "codec": "h264", "duration": 300, "aspect_ratio": 1.777},
      "screenshot": "https://api.put.io/v2/files/42/screenshot",
      "start_from": 125,
      "need_convert": false,
      "is_mp4_available": true,
      "mp4_size": 7340032,
      "mp4_stream_url": "https://api.put.io/v2/files/42/mp4/stream?oauth_token=e2e-token",
      "stream_url": "https://api.put.io/v2/files/42/stream?oauth_token=e2e-token"
    }
    """

    private static let subtitles = """
    {
      "default": "e2e-subtitle",
      "subtitles": [
        {
          "key": "e2e-subtitle",
          "language": "English",
          "language_code": "en",
          "name": "English",
          "source": "uploaded",
          "url": "https://api.put.io/v2/files/42/subtitles/e2e-subtitle",
          "format": "srt"
        }
      ]
    }
    """
}
