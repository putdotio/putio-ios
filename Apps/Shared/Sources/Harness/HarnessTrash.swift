import Foundation

#if DEBUG
  enum HarnessTrash {
    enum Mode: String {
      case board
      case empty
      case slow
      case failing
      case offline
      case moreLoading = "more-loading"
      case moreFailing = "more-failing"

      var isPaged: Bool { self == .moreLoading || self == .moreFailing }
    }

    private struct Item {
      let id: Int
      let name: String
      let fileType: String
      let size: Int64
      let daysLeft: Int
    }

    static let argument = "--putio-harness-trash"
    static let listPath = "/v2/trash/list"
    static let continuePath = "/v2/trash/list/continue"
    static let restorePath = "/v2/trash/restore"
    static let secondPageCursor = "harness-trash-page-2"
    static let slowDelay: TimeInterval = 600
    static let pagedRefreshDelay: TimeInterval = 3
    static let offlineFailures = 2
    static let failingContinues: Set<Int> = [1, 3]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var listsServed = 0
    nonisolated(unsafe) private static var continuesServed = 0
    nonisolated(unsafe) private static var pagedListsRequested = 0
    nonisolated(unsafe) private static var restoredIDs: Set<Int> = []

    static let mode: Mode? = {
      let arguments = ProcessInfo.processInfo.arguments
      guard let flag = arguments.firstIndex(of: argument), arguments.indices.contains(flag + 1)
      else { return nil }
      return Mode(rawValue: arguments[flag + 1])
    }()

    static func handles(method: String, path: String) -> Bool {
      guard let mode else { return false }
      if method == "GET", path == listPath { return true }
      if method == "POST", path == restorePath { return true }
      return mode.isPaged && method == "POST" && path == continuePath
    }

    static func listDelay(method: String, path: String) -> TimeInterval? {
      switch mode {
      case .slow: handles(method: method, path: path) ? slowDelay : nil
      case .moreLoading: method == "POST" && path == continuePath ? slowDelay : nil
      case .moreFailing: refreshesFirstPage(method: method, path: path) ? pagedRefreshDelay : nil
      default: nil
      }
    }

    private static func refreshesFirstPage(method: String, path: String) -> Bool {
      guard method == "GET", path == listPath else { return false }
      return lock.withLock {
        pagedListsRequested += 1
        return pagedListsRequested > 1
      }
    }

    static func consumeOfflineFailure(method: String, path: String) -> Bool {
      guard mode == .offline, handles(method: method, path: path) else { return false }
      return lock.withLock {
        listsServed += 1
        return listsServed <= offlineFailures
      }
    }

    private static let boardItems = [
      Item(id: 4301, name: "Old Season", fileType: "FOLDER", size: 56_000_000, daysLeft: 14),
      Item(
        id: 4302, name: "Blue.Velvet.1986.1080p.BluRay.mkv", fileType: "VIDEO",
        size: 8_700_000_000, daysLeft: 12),
      Item(id: 4303, name: "aspect-235.mp4", fileType: "VIDEO", size: 6_500_000, daysLeft: 12),
      Item(id: 4304, name: "Scans 2025", fileType: "FOLDER", size: 212_000_000, daysLeft: 9),
      Item(
        id: 4305, name: "backup-2026-09.zip", fileType: "ARCHIVE", size: 1_400_000_000,
        daysLeft: 3),
      Item(id: 4306, name: "notes.txt", fileType: "TEXT", size: 2_000, daysLeft: 1),
      Item(id: 4307, name: "poster.jpg", fileType: "IMAGE", size: 2_400_000, daysLeft: 0),
    ]

    private static let secondPageItems = [
      Item(id: 4308, name: "Drafts", fileType: "FOLDER", size: 3_200_000, daysLeft: 8),
      Item(id: 4309, name: "trailer-cut.mp4", fileType: "VIDEO", size: 48_000_000, daysLeft: 6),
      Item(id: 4310, name: "invoice-2026-08.pdf", fileType: "PDF", size: 180_000, daysLeft: 2),
    ]

    private static let boardSize: Int64 = 10_400_000_000

    static func response(method: String, path: String, payload: [String: Any]?) -> (Int, String) {
      if method == "POST", path == restorePath { return restore(payload: payload) }
      guard method == "POST", path == continuePath else { return firstPage() }
      return continuation(cursor: payload?["cursor"] as? String)
    }

    private static func restore(payload: [String: Any]?) -> (Int, String) {
      let raw = (payload?["file_ids"] as? String)?.split(separator: ",") ?? []
      let ids = Set(raw.compactMap { Int($0) })
      let known = Set((boardItems + secondPageItems).map(\.id))
      let restored = lock.withLock {
        guard !ids.isEmpty, ids.count == raw.count, ids.isSubset(of: known),
          ids.isDisjoint(with: restoredIDs)
        else { return false }
        restoredIDs.formUnion(ids)
        return true
      }
      guard restored else {
        return (
          404,
          #"{"status":"ERROR","status_code":404,"error_type":"FILE_NOT_FOUND","message":"Harness Trash restores only listed items"}"#
        )
      }
      return (200, #"{"status":"OK"}"#)
    }

    private static func listed(_ items: [Item]) -> [Item] {
      let restored = lock.withLock { restoredIDs }
      return items.filter { !restored.contains($0.id) }
    }

    private static var restoredSize: Int64 {
      let restored = lock.withLock { restoredIDs }
      return boardItems.filter { restored.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    private static func continuation(cursor: String?) -> (Int, String) {
      guard cursor == secondPageCursor else {
        return (
          400,
          #"{"status":"ERROR","status_code":400,"error_type":"HARNESS_TRASH_CURSOR","message":"Trash continues only from its second-page cursor"}"#
        )
      }
      let shouldFail = lock.withLock {
        continuesServed += 1
        return mode == .moreFailing && failingContinues.contains(continuesServed)
      }
      if shouldFail {
        return (
          500,
          #"{"status":"ERROR","status_code":500,"error_type":"HARNESS_TRASH_CONTINUE","message":"The first and third trash page-two requests fail"}"#
        )
      }
      let rows = listed(secondPageItems).map(json).joined(separator: ",")
      return (
        200,
        #"{"status":"OK","cursor":"","total":\#(boardItems.count + secondPageItems.count),"trash_size":\#(boardSize),"files":[\#(rows)]}"#
      )
    }

    private static func firstPage() -> (Int, String) {
      let shouldFail = lock.withLock {
        guard mode == .failing else { return false }
        listsServed += 1
        return listsServed == 1
      }
      if shouldFail {
        return (
          500,
          #"{"status":"ERROR","status_code":500,"error_type":"HARNESS_TRASH_LIST","message":"The first trash list fails"}"#
        )
      }
      let items = mode == .empty ? [] : listed(boardItems)
      let size = items.isEmpty ? 0 : boardSize - restoredSize
      let rows = items.map(json).joined(separator: ",")
      let paged = mode?.isPaged == true
      let cursor = paged ? secondPageCursor : ""
      let total = paged ? items.count + secondPageItems.count : items.count
      return (
        200,
        #"{"status":"OK","cursor":"\#(cursor)","total":\#(total),"trash_size":\#(size),"files":[\#(rows)]}"#
      )
    }

    private static func json(_ item: Item) -> String {
      #"""
      {"id":\#(item.id),"name":"\#(item.name)","file_type":"\#(item.fileType)",\#
      "parent_id":0,"size":\#(item.size),"created_at":"\#(timestamp(daysFromToday: -30))",\#
      "deleted_at":"\#(timestamp(daysFromToday: item.daysLeft - 14))",\#
      "expiration_date":"\#(timestamp(daysFromToday: item.daysLeft))"}
      """#
    }

    private static func timestamp(daysFromToday days: Int) -> String {
      let calendar = Calendar.current
      let today = calendar.startOfDay(for: .now)
      let day = calendar.date(byAdding: .day, value: days, to: today) ?? today
      let noon = calendar.date(byAdding: .hour, value: 12, to: day) ?? day
      return formatter.string(from: noon)
    }

    private static let formatter: DateFormatter = {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "UTC")
      formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
      return formatter
    }()
  }
#endif
