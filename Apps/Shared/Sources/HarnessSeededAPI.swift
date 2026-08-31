import Foundation

#if DEBUG
  // Deterministic in-process API for signed-in harness scenarios, mirroring
  // the legacy app's E2E mock approach. Anything outside the seeded session
  // and browser surface fails loudly with a named fixture gap.
  final class HarnessSeededAPI: URLProtocol {
    nonisolated(unsafe) static var isEnabled = false
    nonisolated(unsafe) private static var playbackPositions = [411: 90, 412: 0]
    private static let playbackPositionLock = NSLock()

    static let token = "putio-harness-session-token"

    static func resetPlaybackPositions() {
      playbackPositionLock.lock()
      playbackPositions = [411: 90, 412: 0]
      playbackPositionLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
      isEnabled && request.url?.host == "api.put.io"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
      request
    }

    override func startLoading() {
      guard let url = request.url else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      let (statusCode, body) = Self.fixture(for: request)
      let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func fixture(for request: URLRequest) -> (Int, String) {
      guard let url = request.url else {
        return (
          400,
          fixtureError(statusCode: 400, type: "HARNESS_INVALID_REQUEST", message: "Missing URL")
        )
      }
      let routeKey = "\(request.httpMethod ?? "GET") \(url.path)"
      switch routeKey {
      case "GET /v2/oauth2/validate":
        return (
          200,
          #"{"result": true, "token_id": 1, "token_scope": "default", "user_id": 1001}"#
        )
      case "GET /v2/account/info":
        return (200, accountInfo)
      case "POST /v2/oauth/grants/logout":
        return (200, #"{"status":"OK"}"#)
      case "GET /v2/files/list":
        return filesListFixture(url: url)
      case "GET /v2/files/411":
        return (
          200,
          playbackFile(
            id: 411,
            name: "Nested Movie.mkv",
            startFrom: playbackPosition(fileID: 411)
          )
        )
      case "GET /v2/files/412":
        return (
          200,
          playbackFile(
            id: 412,
            name: "Root Movie.mkv",
            startFrom: playbackPosition(fileID: 412)
          )
        )
      case "POST /v2/files/411/start-from/set":
        return setPlaybackPosition(request: request, fileID: 411)
      case "POST /v2/files/412/start-from/set":
        return setPlaybackPosition(request: request, fileID: 412)
      default:
        return (
          404,
          fixtureError(
            statusCode: 404,
            type: "HARNESS_FIXTURE_NOT_FOUND",
            message: "No harness fixture for \(routeKey)"
          )
        )
      }
    }

    private static func filesListFixture(url: URL) -> (Int, String) {
      let parentID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "parent_id" })?
        .value
        .flatMap(Int.init)
      switch parentID {
      case 0:
        return (200, rootFiles)
      case 410:
        return (200, nestedFiles)
      case .none:
        return (
          400,
          fixtureError(
            statusCode: 400,
            type: "HARNESS_PARENT_ID_REQUIRED",
            message: "The files fixture requires parent_id"
          )
        )
      case .some(let parentID):
        return (
          404,
          fixtureError(
            statusCode: 404,
            type: "HARNESS_FOLDER_NOT_FOUND",
            message: "No harness folder fixture for parent_id=\(parentID)"
          )
        )
      }
    }

    private static func fixtureError(statusCode: Int, type: String, message: String) -> String {
      """
      {
        "status": "ERROR",
        "status_code": \(statusCode),
        "error_type": "\(type)",
        "message": "\(message)"
      }
      """
    }

    private static func playbackPosition(fileID: Int) -> Int {
      playbackPositionLock.lock()
      defer { playbackPositionLock.unlock() }
      return playbackPositions[fileID] ?? 0
    }

    private static func setPlaybackPosition(request: URLRequest, fileID: Int) -> (Int, String) {
      guard
        let body = requestBodyData(request),
        let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let seconds = payload["time"] as? Int,
        seconds >= 0
      else {
        return (
          400,
          fixtureError(
            statusCode: 400,
            type: "HARNESS_POSITION_REQUIRED",
            message: "The playback-position fixture requires a nonnegative integer time"
          )
        )
      }

      playbackPositionLock.lock()
      playbackPositions[fileID] = seconds
      playbackPositionLock.unlock()
      return (200, #"{"status":"OK"}"#)
    }

    private static func requestBodyData(_ request: URLRequest) -> Data? {
      if let body = request.httpBody {
        return body
      }
      guard let stream = request.httpBodyStream else { return nil }

      stream.open()
      defer { stream.close() }
      let bufferSize = 1_024
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
      defer { buffer.deallocate() }

      var body = Data()
      while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        guard count >= 0 else { return nil }
        guard count > 0 else { break }
        body.append(buffer, count: count)
      }
      return body
    }

    private static let accountInfo = """
      {
        "info": {
          "user_id": 1001,
          "username": "moviebuff",
          "mail": "harness@example.com",
          "avatar_url": "https://static.put.io/e2e-avatar.png",
          "user_hash": "harness-hash",
          "features": {},
          "download_token": "harness-download-token",
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

    private static let rootFiles = """
      {
        "parent": {
          "id": 0,
          "name": "Your Files",
          "file_type": "FOLDER",
          "parent_id": 0,
          "size": 0,
          "created_at": "2026-08-01T10:00:00Z",
          "updated_at": "2026-08-01T10:00:00Z"
        },
        "files": [
          {
            "id": 410,
            "name": "Harness Folder",
            "file_type": "FOLDER",
            "parent_id": 0,
            "size": 0,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z"
          },
          {
            "id": 412,
            "name": "Root Movie.mkv",
            "file_type": "VIDEO",
            "parent_id": 0,
            "size": 734003200,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z",
            "start_from": 0
          },
          {
            "id": 413,
            "name": "Document.pdf",
            "file_type": "PDF",
            "parent_id": 0,
            "size": 1048576,
            "created_at": "2026-08-28T10:00:00Z",
            "updated_at": "2026-08-29T10:00:00Z"
          }
        ],
        "total": 3
      }
      """

    private static let nestedFiles = """
      {
        "parent": {
          "id": 410,
          "name": "Harness Folder",
          "file_type": "FOLDER",
          "parent_id": 0,
          "size": 0,
          "created_at": "2026-08-28T10:00:00Z",
          "updated_at": "2026-08-29T10:00:00Z"
        },
        "files": [
          {
            "id": 411,
            "name": "Nested Movie.mkv",
            "file_type": "VIDEO",
            "parent_id": 410,
            "size": 1073741824,
            "created_at": "2026-08-28T11:00:00Z",
            "updated_at": "2026-08-29T11:00:00Z",
            "start_from": 90
          }
        ],
        "total": 1
      }
      """

    private static func playbackFile(id: Int, name: String, startFrom: Int) -> String {
      """
      {
        "file": {
          "id": \(id),
          "name": "\(name)",
          "file_type": "VIDEO",
          "need_convert": false,
          "start_from": \(startFrom)
        }
      }
      """
    }
  }
#endif
