import Foundation

#if DEBUG
// swiftlint:disable static_over_final_class
final class PutioE2EMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard ProcessInfo.processInfo.environment["PUTIO_E2E_MOCK_API"] == "1" else {
            return false
        }

        return request.url?.host == "api.put.io"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let fixture = PutioE2EMockAPI.fixture(for: request, url: url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": fixture.contentType]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
// swiftlint:enable static_over_final_class

private enum PutioE2EMockAPI {
    struct Fixture {
        let statusCode: Int
        let contentType: String
        let body: Data

        init(statusCode: Int = 200, contentType: String = "application/json", body: String) {
            self.statusCode = statusCode
            self.contentType = contentType
            self.body = Data(body.utf8)
        }
    }

    static func fixture(for request: URLRequest, url: URL) -> Fixture {
        let routeKey = "\(request.httpMethod ?? "GET") \(url.path)"

        if failRoutes.contains(routeKey) {
            return Fixture(statusCode: 500, body: """
            {
              "status": "ERROR",
              "status_code": 500,
              "error_type": "E2E_FORCED_FAILURE",
              "message": "Forced failure for \(routeKey)"
            }
            """)
        }

        if routeKey == "GET /v2/files/42/hls/media.m3u8" || routeKey == "GET /v2/files/43/hls/media.m3u8" {
            return Fixture(contentType: "application/vnd.apple.mpegurl", body: hlsPlaylist)
        }

        if let fixture = routes[routeKey] {
            return fixture
        }

        return Fixture(statusCode: 404, body: """
        {
          "status": "ERROR",
          "status_code": 404,
          "error_type": "E2E_FIXTURE_NOT_FOUND",
          "message": "No e2e fixture for \(request.httpMethod ?? "GET") \(url.path)"
        }
        """)
    }

    // Route keys ("METHOD /path", comma-separated) that return a 500 error
    // fixture, so tests can exercise failure states.
    private static let failRoutes: Set<String> = {
        guard let raw = ProcessInfo.processInfo.environment["PUTIO_E2E_FAIL_ROUTES"] else {
            return []
        }

        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }()

    private static let ok = #"{"status":"OK"}"#

    private static let routes: [String: Fixture] = [
        "GET /v2/account/info": Fixture(body: accountInfo),
        "GET /v2/config": Fixture(body: config),
        "GET /v2/files/list": Fixture(body: filesList),
        "GET /v2/files/42": Fixture(body: fileDetails),
        "GET /v2/files/42/start-from": Fixture(body: #"{"start_from":125}"#),
        "POST /v2/files/42/start-from/set": Fixture(body: ok),
        "GET /v2/files/42/start-from/delete": Fixture(body: ok),
        "GET /v2/files/42/subtitles": Fixture(body: subtitles),
        "GET /v2/files/42/next-file": Fixture(body: nextFile),
        "GET /v2/files/42/mp4": Fixture(body: mp4Status),
        "POST /v2/files/42/mp4": Fixture(body: ok),
        "POST /v2/ifttt-client/event": Fixture(body: ok),
        "GET /v2/events/list": Fixture(body: historyEvents),
        "GET /v2/trash/list": Fixture(body: trashList),
        "GET /v2/tunnel/routes": Fixture(body: tunnelRoutes),
        "GET /v2/oauth/grants": Fixture(body: grants),
        "GET /v2/files/43": Fixture(body: audioFileDetails),
        "GET /v2/files/43/start-from": Fixture(body: #"{"start_from":0}"#),
        "GET /v2/files/43/next-file": Fixture(body: #"{"next_file":null}"#),
        "GET /v2/files/43/subtitles": Fixture(body: #"{"default":null,"subtitles":[]}"#)
    ]

    private static let tunnelRoutes = """
    {
      "status": "OK",
      "routes": [
        { "name": "default", "description": "Fastest route for your location", "hosts": [] },
        { "name": "ams", "description": "Amsterdam", "hosts": [] },
        { "name": "fra", "description": "Frankfurt", "hosts": [] }
      ]
    }
    """

    private static let grants = """
    {
      "status": "OK",
      "apps": [
        {
          "id": 5001,
          "name": "put.io Web",
          "description": "Browser session",
          "website": "https://app.put.io",
          "has_icon": false
        },
        {
          "id": 5002,
          "name": "put.io for Apple TV",
          "description": "Living room",
          "website": "https://put.io",
          "has_icon": false
        }
      ]
    }
    """

    // The trash row renders expiration_date as an absolute "Expires on
    // <month day>" label, so these stay fixed — a relative date would shift
    // the rendered text daily and break screenshot baselines.
    private static let trashList = """
    {
      "status": "OK",
      "cursor": null,
      "total": 1,
      "trash_size": 189792256,
      "files": [
        {
          "id": 77,
          "name": "Elephants Dream.mp4",
          "icon": "video",
          "parent_id": 0,
          "size": 189792256,
          "created_at": "2026-04-24T10:00:00Z",
          "updated_at": "2026-04-24T10:00:00Z",
          "file_type": "VIDEO",
          "is_shared": false,
          "sort_by": "NAME_ASC",
          "deleted_at": "2026-07-14T10:00:00Z",
          "expiration_date": "2026-08-14T10:00:00Z"
        }
      ]
    }
    """

    private static let accountInfo = """
    {
      "info": {
        "user_id": 1001,
        "username": "moviebuff",
        "mail": "e2e@example.com",
        "avatar_url": "https://static.put.io/e2e-avatar.png",
        "user_hash": "e2e-hash",
        "features": {},
        "download_token": "e2e-download-token",
        "trash_size": 189792256,
        "account_active": true,
        "files_will_be_deleted_at": "",
        "password_last_changed_at": "",
        "disk": {
          "avail": 1068893827072,
          "size": 1099511627776,
          "used": 30617800704
        },
        "settings": {
          "tunnel_route_name": "default",
          "next_episode": true,
          "start_from": true,
          "history_enabled": true,
          "trash_enabled": true,
          "sort_by": "NAME_ASC",
          "show_optimistic_usage": false,
          "two_factor_enabled": false,
          "hide_subtitles": false,
          "dont_autoselect_subtitles": false
        }
      }
    }
    """

    private static let config = """
    {
      "config": {
        "chromecast_playback_type": "hls"
      }
    }
    """

    private static let filesList = """
    {
      "parent": {
        "id": 0,
        "name": "Home",
        "icon": "folder",
        "parent_id": 0,
        "size": 0,
        "created_at": "2026-04-24T10:00:00Z",
        "updated_at": "2026-04-24T10:00:00Z",
        "file_type": "FOLDER",
        "is_shared": false,
        "sort_by": "NAME_ASC"
      },
      "files": [
        \(rootFiles.joined(separator: ",\n"))
      ],
      "cursor": null,
      "total": \(rootFiles.count)
    }
    """

    // One array so `total` is counted rather than tallied by hand. It was
    // `6 + 2 + libraryTitles.count`, which would have gone quietly wrong the
    // first time someone added a folder.
    private static let rootFiles: [String] =
        [
            folder(id: 101, name: "Downloads", size: 3_221_225_472),
            folder(id: 102, name: "Movies", size: 8_589_934_592),
            folder(id: 103, name: "Music", size: 1_073_741_824),
            folder(id: 104, name: "Pictures", size: 268_435_456),
            folder(id: 105, name: "Series", size: 12_884_901_888),
            folder(id: 106, name: "Items shared with you", size: 4_294_967_296),
            videoFile,
            audioFile
        ] + libraryFiles

    // Rows past the eight the walk actually interacts with. They exist so the
    // list reaches the bottom of a 13-inch iPad, which is what the App Store set
    // is cropped from — eight rows left the lower half of slot 1 black (#86).
    //
    // Appended rather than interleaved: ids 42 and 43 stay at positions 7 and 8,
    // so every element the walk looks up is where it was, and no navigation
    // changes.
    //
    // All Blender Studio open movies, like the fixtures above. These names reach
    // the App Store listing, so they are deliberately free content rather than
    // titles that would imply a catalogue put.io does not have.
    private static let libraryTitles = [
        "Agent 327 - Operation Barbershop",
        "Caminandes - Gran Dillama",
        "Charge",
        "Coffee Run",
        "Dogwalk",
        "Glass Half",
        "Hero",
        "Nina",
        "Pets",
        "Settlers",
        "Sprite Fright",
        "The Daily Dweebs",
        "Wing It!"
    ]

    private static let libraryFiles: [String] = libraryTitles
        .enumerated()
        .map { index, title in
            // Sizes vary so the subtitle column does not read as a repeated
            // string, and are derived from the index so they stay fixed across
            // runs — a random size would move pixels in a compared baseline.
            libraryFile(id: 200 + index, name: "\(title).mp4", size: 314_572_800 + index * 41_943_040)
        }

    private static func libraryFile(id: Int, name: String, size: Int) -> String {
      """
      {
        "id": \(id),
        "name": "\(name)",
        "icon": "video",
        "parent_id": 0,
        "size": \(size),
        "created_at": "\(fixtureFileDate)",
        "updated_at": "\(fixtureFileDate)",
        "file_type": "VIDEO",
        "is_shared": false,
        "sort_by": "NAME_ASC",
        "need_convert": false,
        "is_mp4_available": true
      }
      """
    }

    private static func folder(id: Int, name: String, size: Int) -> String {
      """
      {
        "id": \(id),
        "name": "\(name)",
        "icon": "folder",
        "parent_id": 0,
        "size": \(size),
        "created_at": "\(fixtureFileDate)",
        "updated_at": "\(fixtureFileDate)",
        "file_type": "FOLDER",
        "is_shared": false,
        "sort_by": "NAME_ASC"
      }
      """
    }


    // Streams point at the HLS playlist fixture so AVPlayer reaches a ready
    // state without real media bytes.
    private static let audioFile = """
    {
      "id": 43,
      "name": "Sintel Theme.mp3",
      "icon": "audio",
      "parent_id": 0,
      "size": 8388608,
      "created_at": "\(fixtureFileDate)",
      "updated_at": "\(fixtureFileDate)",
      "file_type": "AUDIO",
      "is_shared": false,
      "sort_by": "NAME_ASC",
      "stream_url": "https://api.put.io/v2/files/43/hls/media.m3u8",
      "mp4_stream_url": "https://api.put.io/v2/files/43/hls/media.m3u8"
    }
    """

    private static let audioFileDetails = """
    {
      "file": \(audioFile)
    }
    """

    private static let fileDetails = """
    {
      "file": \(videoFile)
    }
    """

    // Two hours back renders "2 hours ago" in every calendar; day-scale
    // offsets can straddle month buckets and destabilize snapshot baselines.
    private static let fixtureFileDate: String = {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60 * 2))
    }()

    private static let videoFile = """
    {
      "id": 42,
      "name": "Big Buck Bunny.mp4",
      "icon": "video",
      "parent_id": 0,
      "size": 276205568,
      "created_at": "\(fixtureFileDate)",
      "updated_at": "\(fixtureFileDate)",
      "file_type": "VIDEO",
      "is_shared": false,
      "sort_by": "NAME_ASC",
      "video_metadata": {
        "height": 720,
        "width": 1280,
        "codec": "h264",
        "duration": 300,
        "aspect_ratio": 1.777
      },
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

    private static let nextFile = """
    {
      "next_file": {
        "id": 44,
        "name": "Sintel.mp4",
        "parent_id": 0,
        "file_type": "VIDEO"
      }
    }
    """

    private static let mp4Status = """
    {
      "mp4": {
        "status": "COMPLETED",
        "percent_done": 100,
        "start_from": 0
      }
    }
    """

    private static let hlsPlaylist = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:1
    #EXT-X-ENDLIST
    """

    // Dates are computed at first access so the fixture events always land in the
    // Today / Yesterday / Ancient Times buckets regardless of when tests run.
    private static let historyEvents: String = {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let today = formatter.string(from: now.addingTimeInterval(-60 * 60))
        let yesterday = formatter.string(from: now.addingTimeInterval(-60 * 60 * 25))
        let ancient = formatter.string(from: now.addingTimeInterval(-60 * 60 * 24 * 30))

        return """
        {
          "status": "OK",
          "has_more": false,
          "events": [
            {
              "id": 9001,
              "user_id": 1001,
              "type": "upload",
              "created_at": "\(today)",
              "file_id": 78,
              "file_name": "Tears of Steel.mp4",
              "file_size": 734003200
            },
            {
              "id": 9002,
              "user_id": 1001,
              "type": "transfer_completed",
              "created_at": "\(yesterday)",
              "file_id": 79,
              "transfer_name": "Cosmos Laundromat",
              "transfer_size": 1073741824,
              "source": "magnet"
            },
            {
              "id": 9003,
              "user_id": 1001,
              "type": "file_shared",
              "created_at": "\(ancient)",
              "file_id": 80,
              "file_name": "Caminandes - Llama Drama.mp4",
              "sharing_user_name": "sam"
            }
          ]
        }
        """
    }()
}
#endif
