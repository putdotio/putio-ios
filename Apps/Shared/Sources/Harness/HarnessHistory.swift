import Foundation

#if DEBUG
  enum HarnessHistory {
    enum Mode: String {
      case board
      case slow
      case empty
      case failing
      case offline
      case moreHeld = "more-held"
      case moreFails = "more-fails"
    }

    static let argument = "--putio-harness-history"
    static let listPath = "/v2/events/list"
    static let slowDelay: TimeInterval = 600
    static let offlineFailures = 2

    private static let lock = NSLock()
    nonisolated(unsafe) private static var rootListsServed = 0
    nonisolated(unsafe) private static var heldList: ObjectIdentifier?

    static let mode: Mode? = {
      let arguments = ProcessInfo.processInfo.arguments
      guard let flag = arguments.firstIndex(of: argument), arguments.indices.contains(flag + 1)
      else { return nil }
      return Mode(rawValue: arguments[flag + 1])
    }()

    static func handles(method: String, url: URL) -> Bool {
      guard mode != nil, method == "GET", url.path == listPath else { return false }
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      return !query.contains { $0.name == "before" }
    }

    static func handlesPage(method: String, url: URL) -> Bool {
      guard mode == .moreHeld || mode == .moreFails, method == "GET", url.path == listPath
      else { return false }
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      return query.contains { $0.name == "before" }
    }

    static func holdsPage(method: String, url: URL) -> Bool {
      mode == .moreHeld && handlesPage(method: method, url: url)
    }

    static func delaysList(method: String, url: URL) -> Bool {
      guard mode == .slow, handles(method: method, url: url) else { return false }
      return lock.withLock { rootListsServed == 1 }
    }

    static func hold(_ request: AnyObject) {
      lock.withLock { heldList = ObjectIdentifier(request) }
    }

    static func release(_ request: AnyObject) {
      lock.withLock {
        if heldList == ObjectIdentifier(request) { heldList = nil }
      }
    }

    static func consumeOfflineFailure(method: String, url: URL) -> Bool {
      guard mode == .offline, handles(method: method, url: url) else { return false }
      return lock.withLock {
        rootListsServed += 1
        return rootListsServed <= offlineFailures
      }
    }

    static func response(excluding deletedIDs: Set<Int>) -> (Int, String) {
      let (first, overlapsHeldList) = lock.withLock {
        if mode != .offline { rootListsServed += 1 }
        return (rootListsServed == 1, heldList != nil)
      }
      switch mode {
      case .slow where overlapsHeldList:
        return (
          409,
          #"{"status":"ERROR","status_code":409,"error_type":"HARNESS_HISTORY_UNCANCELLED","message":"The held history list was never cancelled"}"#
        )
      case .empty where first:
        return (200, #"{"status":"OK","has_more":false,"events":[]}"#)
      case .failing where first:
        return (
          503,
          #"{"status":"ERROR","status_code":503,"error_type":"HARNESS_HISTORY_LOAD","message":"The first history list fails"}"#
        )
      default:
        return (200, boardEvents(excluding: deletedIDs))
      }
    }

    private static func boardEvents(excluding deletedIDs: Set<Int>) -> String {
      let calendar = Calendar.current
      let today = calendar.startOfDay(for: Date())
      let formatter = ISO8601DateFormatter()
      func event(
        _ id: Int, _ type: String, daysAgo: Int, hour: Int, minute: Int, fields: String
      ) -> (Int, String) {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
        let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        return (
          id,
          #"{"id":\#(id),"user_id":1,"type":"\#(type)","created_at":"\#(formatter.string(from: date))",\#(fields)}"#
        )
      }
      let events = [
        event(
          907, "file_shared", daysAgo: 0, hour: 18, minute: 15,
          fields:
            #""file_name":"FFTT Tree Rings November 10, 2026.mp3","file_size":4096,"sharing_user_name":"Fixture Friend","file_id":0"#
        ),
        event(
          906, "transfer_completed", daysAgo: 0, hour: 14, minute: 2,
          fields:
            #""transfer_name":"Blue.Lights.S04E04.1080p.HDTV.H264-ORGANiC.mkv","transfer_size":1073741824,"file_id":0"#
        ),
        event(
          905, "upload", daysAgo: 1, hour: 20, minute: 36,
          fields: #""file_name":"document-scan-march-2026.pdf","file_size":2048,"file_id":0"#),
        event(
          904, "transfer_error", daysAgo: 1, hour: 20, minute: 12,
          fields: #""transfer_name":"ubuntu-24.04.1-desktop-amd64.iso""#),
        event(
          903, "rss_filter_paused", daysAgo: 1, hour: 7, minute: 40,
          fields: #""rss_filter_title":"Weekly Episodes""#),
        event(
          902, "upload", daysAgo: 2, hour: 21, minute: 58,
          fields: #""file_name":"IMG_4392.HEIC","file_size":2048,"file_id":0"#),
        event(
          901, "file_from_rss_deleted_for_space", daysAgo: 2, hour: 3, minute: 10,
          fields: #""file_name":"Old.Episode.S01E01.mkv","file_size":1024"#),
      ]
      let kept = events.filter { !deletedIDs.contains($0.0) }.map(\.1)
      let hasMore = mode == .moreHeld || mode == .moreFails
      return
        #"{"status":"OK","has_more":\#(hasMore),"events":[\#(kept.joined(separator: ","))]}"#
    }
  }
#endif
