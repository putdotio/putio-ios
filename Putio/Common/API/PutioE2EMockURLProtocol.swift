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

        if routeKey == "GET /v2/files/42/hls/media.m3u8" {
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
        "GET /v2/trash/list": Fixture(body: trashList)
    ]

    // The trash row renders expiration_date as an absolute "Expires on
    // <month day>" label, so these stay fixed — a relative date would shift
    // the rendered text daily and break screenshot baselines.
    private static let trashList = """
    {
      "status": "OK",
      "cursor": null,
      "total": 1,
      "trash_size": 7340032,
      "files": [
        {
          "id": 77,
          "name": "E2E Trashed Movie.mp4",
          "icon": "video",
          "parent_id": 0,
          "size": 7340032,
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
        "username": "e2e-user",
        "mail": "e2e@example.com",
        "avatar_url": "https://static.put.io/e2e-avatar.png",
        "user_hash": "e2e-hash",
        "features": {},
        "download_token": "e2e-download-token",
        "trash_size": 0,
        "account_active": true,
        "files_will_be_deleted_at": "",
        "password_last_changed_at": "",
        "disk": {
          "avail": 1024,
          "size": 2048,
          "used": 1024
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
        \(videoFile)
      ],
      "cursor": null,
      "total": 1
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
      "name": "E2E Movie.mp4",
      "icon": "video",
      "parent_id": 0,
      "size": 7340032,
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
        "id": 43,
        "name": "E2E Movie Part 2.mp4",
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
              "file_id": 42,
              "file_name": "E2E Upload.mp4",
              "file_size": 7340032
            },
            {
              "id": 9002,
              "user_id": 1001,
              "type": "transfer_completed",
              "created_at": "\(yesterday)",
              "file_id": 42,
              "transfer_name": "E2E Transfer",
              "transfer_size": 7340032,
              "source": "magnet"
            },
            {
              "id": 9003,
              "user_id": 1001,
              "type": "file_shared",
              "created_at": "\(ancient)",
              "file_id": 42,
              "file_name": "E2E Shared File.mp4",
              "sharing_user_name": "e2e-friend"
            }
          ]
        }
        """
    }()
}
#endif
