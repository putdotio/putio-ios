import Foundation

#if DEBUG
  enum HarnessTrash {
    enum Mode: String {
      case board
      case empty
      case slow
      case failing
      case offline
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
    static let slowDelay: TimeInterval = 600
    static let offlineFailures = 2

    private static let lock = NSLock()
    nonisolated(unsafe) private static var listsServed = 0

    static let mode: Mode? = {
      let arguments = ProcessInfo.processInfo.arguments
      guard let flag = arguments.firstIndex(of: argument), arguments.indices.contains(flag + 1)
      else { return nil }
      return Mode(rawValue: arguments[flag + 1])
    }()

    static func handles(method: String, path: String) -> Bool {
      mode != nil && method == "GET" && path == listPath
    }

    static func delaysList(method: String, path: String) -> Bool {
      mode == .slow && handles(method: method, path: path)
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

    private static let boardSize: Int64 = 10_400_000_000

    static func response() -> (Int, String) {
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
      let items = mode == .empty ? [] : boardItems
      let size = items.isEmpty ? 0 : boardSize
      let rows = items.map(json).joined(separator: ",")
      return (
        200,
        #"{"status":"OK","cursor":"","total":\#(items.count),"trash_size":\#(size),"files":[\#(rows)]}"#
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
