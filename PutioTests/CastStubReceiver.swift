import GoogleCast
@testable import Putio

final class StubCastReceiver: GCKDeviceProvider {
    private(set) lazy var device: GCKDevice = {
        let device = createDevice(
            withID: "stub_receiver",
            networkAddress: GCKNetworkAddress(iPv4Address: "127.0.0.1"),
            servicePort: 8009
        )
        device.friendlyName = "Stub receiver"
        device.modelName = "Stub"
        return device
    }()

    private(set) var session: StubCastSession?

    init() {
        super.init(deviceCategory: kGCKCastDeviceCategory)
    }

    override func startDiscovery() {
        DispatchQueue.main.async {
            self.notifyDidStartDiscovery()
            self.notifyDidPublishDevice(self.device)
        }
    }

    override func stopDiscovery() {}

    override func createSession(for device: GCKDevice, sessionID: String?, sessionOptions: [String: any NSCoding & NSObjectProtocol]?) -> GCKSession {
        let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: CHROMECAST_RECEIVER_APP_ID))
        let session = StubCastSession(device: device, sessionID: sessionID, sessionOptions: sessionOptions, castOptions: options)
        self.session = session
        return session
    }
}

final class StubCastSession: GCKCastSession {
    let client = StubRemoteMediaClient()
    private(set) var endAction: GCKSessionEndAction?

    override var remoteMediaClient: GCKRemoteMediaClient? { client }

    override func start() {
        DispatchQueue.main.async { self.notifyDidStart(withSessionID: "stub-session") }
    }

    override func end(with action: GCKSessionEndAction) {
        endAction = action
        DispatchQueue.main.async { self.notifyDidEndWithError(nil, willTryToResume: false) }
    }
}

final class StubRemoteMediaClient: GCKRemoteMediaClient {
    enum Command: Equatable {
        case load(contentID: String?, autoplay: Bool, position: TimeInterval)
        case play
        case pause
        case seek(interval: TimeInterval, relative: Bool)
    }

    private(set) var commands: [Command] = []
    private(set) var loadedMedia: GCKMediaInformation?
    private(set) var loadOptions: GCKMediaLoadOptions?
    private var status: StubMediaStatus?
    private var pendingLoad: GCKRequest?

    override var connected: Bool { true }
    override var mediaStatus: GCKMediaStatus? { status }

    override func approximateStreamPosition() -> TimeInterval {
        status?.position ?? 0
    }

    override func loadMedia(_ mediaInfo: GCKMediaInformation, with options: GCKMediaLoadOptions) -> GCKRequest {
        loadedMedia = mediaInfo
        loadOptions = options
        commands.append(.load(contentID: mediaInfo.contentID, autoplay: options.autoplay, position: options.playPosition))
        let request = GCKRequest.application()
        pendingLoad = request
        return request
    }

    func finishLoading() {
        guard let request = pendingLoad, let media = loadedMedia, let options = loadOptions else { return }
        pendingLoad = nil
        update(StubMediaStatus(media: media, playerState: options.autoplay ? .playing : .paused, position: options.playPosition))
        notifyDidStartMediaSession()
        request.complete()
    }

    override func play() -> GCKRequest {
        commands.append(.play)
        return answer { $0.state = .playing }
    }

    override func pause() -> GCKRequest {
        commands.append(.pause)
        return answer { $0.state = .paused }
    }

    override func seek(with options: GCKMediaSeekOptions) -> GCKRequest {
        commands.append(.seek(interval: options.interval, relative: options.relative))
        return answer { status in
            status.position = options.relative ? status.position + options.interval : options.interval
        }
    }

    private func answer(_ change: (StubMediaStatus) -> Void) -> GCKRequest {
        let request = GCKRequest.application()
        if let status {
            change(status)
            update(status)
        }
        DispatchQueue.main.async { request.complete() }
        return request
    }

    private func update(_ status: StubMediaStatus) {
        self.status = status
        notifyDidUpdateMediaStatus()
    }
}

final class StubMediaStatus: GCKMediaStatus {
    var state: GCKMediaPlayerState
    var position: TimeInterval

    init(media: GCKMediaInformation, playerState: GCKMediaPlayerState, position: TimeInterval) {
        state = playerState
        self.position = position
        super.init(sessionID: 1, mediaInformation: media)
    }

    override var playerState: GCKMediaPlayerState { state }

    override var streamPosition: TimeInterval { position }

    override func isMediaCommandSupported(_ command: Int) -> Bool { true }
}
