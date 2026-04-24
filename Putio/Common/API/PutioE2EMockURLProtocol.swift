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
        "POST /v2/ifttt-client/event": Fixture(body: ok)
    ]

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

    private static let videoFile = """
    {
      "id": 42,
      "name": "E2E Movie.mp4",
      "icon": "video",
      "parent_id": 0,
      "size": 7340032,
      "created_at": "2026-04-24T10:00:00Z",
      "updated_at": "2026-04-24T10:00:00Z",
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
}
#endif
