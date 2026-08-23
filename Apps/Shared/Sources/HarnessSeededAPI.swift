import Foundation

#if DEBUG
  // Deterministic in-process API for the harness signed-in scenario, mirroring
  // the legacy app's E2E mock approach. Serves only the session endpoints this
  // scenario needs; anything else fails loudly with a named fixture gap.
  final class HarnessSeededAPI: URLProtocol {
    nonisolated(unsafe) static var isEnabled = false

    static let token = "putio-harness-session-token"

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
      let routeKey = "\(request.httpMethod ?? "GET") \(url.path)"
      let (statusCode, body) = Self.fixture(for: routeKey)
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

    private static func fixture(for routeKey: String) -> (Int, String) {
      switch routeKey {
      case "GET /v2/oauth2/validate":
        (200, #"{"result": true, "token_id": 1, "token_scope": "default", "user_id": 1001}"#)
      case "GET /v2/account/info":
        (200, accountInfo)
      case "POST /v2/oauth/grants/logout":
        (200, #"{"status":"OK"}"#)
      default:
        (
          404,
          """
          {
            "status": "ERROR",
            "status_code": 404,
            "error_type": "HARNESS_FIXTURE_NOT_FOUND",
            "message": "No harness fixture for \(routeKey)"
          }
          """
        )
      }
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
  }
#endif
