import Foundation

#if DEBUG
  enum HarnessPublicLinks {
    enum Mode: String {
      case ready
      case journey
      case slow
      case failing
      case empty
    }

    private struct Link {
      let id: Int
      let token: String
      let fileID: Int
      let name: String
      let fileType: String
      let expiresInHours: Double?
    }

    enum CreateMode: String {
      case ready
      case slow
      case refusals
      case failing
    }

    static let argument = "--putio-harness-public-links"
    static let createArgument = "--putio-harness-public-link-create"
    static let createDelay: TimeInterval = 600
    static let refusals = [
      "PUBLIC_SHARE_NOT_ALLOWED_PLAN", "PUBLIC_SHARE_UNSUPPORTED_FILE_TYPE",
      "PUBLIC_SHARE_EXCEEDED_LIMIT", "PUBLIC_SHARE_FOLDER_MAX_SIZE_LIMIT_EXCEEDED",
      "PUBLIC_SHARE_FOLDER_MAX_CHILDREN_LIMIT_EXCEEDED",
      "PUBLIC_SHARE_DAILY_TOTAL_LINK_COUNT_EXCEEDED",
      "PUBLIC_SHARE_WEEKLY_TOTAL_LINK_COUNT_EXCEEDED",
    ]
    static let listPath = "/v2/public_share/list"
    static let pathPrefix = "/v2/public_share/"
    static let slowDelay: TimeInterval = 6
    static let failingRevokeID = 902

    private static let lock = NSLock()
    nonisolated(unsafe) private static var links: [Link]?
    nonisolated(unsafe) private static var listsServed = 0
    nonisolated(unsafe) private static var revokeFailed = false
    nonisolated(unsafe) private static var createsServed = 0

    static let mode: Mode = {
      let arguments = ProcessInfo.processInfo.arguments
      guard let flag = arguments.firstIndex(of: argument), arguments.indices.contains(flag + 1)
      else { return .empty }
      return Mode(rawValue: arguments[flag + 1]) ?? .empty
    }()

    static let createMode: CreateMode = {
      let arguments = ProcessInfo.processInfo.arguments
      guard let flag = arguments.firstIndex(of: createArgument),
        arguments.indices.contains(flag + 1)
      else { return .ready }
      return CreateMode(rawValue: arguments[flag + 1]) ?? .ready
    }()

    static var delaysList: Bool { mode == .slow }

    static func delaysCreate(method: String, path: String) -> Bool {
      createMode == .slow && method == "POST" && fileID(in: path) != nil
    }

    private static func fileID(in path: String) -> Int? {
      guard path.hasPrefix(pathPrefix) else { return nil }
      return Int(path.dropFirst(pathPrefix.count))
    }

    static func handles(method: String, path: String) -> Bool {
      path == listPath && method == "GET"
        || (method == "DELETE" || method == "POST") && fileID(in: path) != nil
    }

    private static let boardLinks = [
      Link(
        id: 901, token: "hX7kQ2pLm9", fileID: 4101,
        name: "Blue.Lights.S04E01.1080p.WEB.H264-ORGANiC.mkv", fileType: "VIDEO",
        expiresInHours: 71.5),
      Link(
        id: 902, token: "Rt4vW8nZq1", fileID: 4102, name: "Sintel.2010.1080p.mkv",
        fileType: "VIDEO", expiresInHours: 38.5),
      Link(
        id: 903, token: "Jc2sY6bTe5", fileID: 4103, name: "IMG_4392.HEIC", fileType: "IMAGE",
        expiresInHours: 2.5),
      Link(
        id: 904, token: "Kd8fP3gUa7", fileID: 4104, name: "Expired.Trailer.mkv",
        fileType: "VIDEO", expiresInHours: -1),
    ]

    private static let undatedLink = Link(
      id: 905, token: "Mb5hR1cVo3", fileID: 4105, name: "Cosmos.Laundromat.2015.mkv",
      fileType: "VIDEO", expiresInHours: nil)

    private static let laterLink = Link(
      id: 906, token: "Pq9wE4xLs2", fileID: 4106, name: "Big.Buck.Bunny.2008.mkv",
      fileType: "VIDEO", expiresInHours: 71.9)

    static func response(method: String, path: String) -> (Int, String) {
      lock.withLock {
        let current = links ?? initialLinks
        links = current
        if method == "GET", path == listPath {
          return list(current)
        }
        if method == "POST", let fileID = fileID(in: path) {
          return create(fileID: fileID, current: current)
        }
        guard method == "DELETE", let id = Int(path.dropFirst(pathPrefix.count)) else {
          return failure(404, "HARNESS_FIXTURE_NOT_FOUND", "No public share fixture for \(path)")
        }
        guard current.contains(where: { $0.id == id }) else {
          return failure(404, "NOT_FOUND", "Public share not found")
        }
        if mode == .journey, id == failingRevokeID, !revokeFailed {
          revokeFailed = true
          return failure(503, "HARNESS_PUBLIC_SHARE_REVOKE", "Retry revoking the link")
        }
        links = current.filter { $0.id != id }
        return (200, #"{"status":"OK"}"#)
      }
    }

    private static let createdToken = "8f3KxQ2mVt7"

    private static func create(fileID: Int, current: [Link]) -> (Int, String) {
      createsServed += 1
      switch createMode {
      case .refusals where createsServed <= refusals.count:
        return failure(403, refusals[createsServed - 1], "Public share refused")
      case .failing where createsServed == 1:
        return failure(500, "HARNESS_PUBLIC_SHARE_CREATE", "The first link creation fails")
      default:
        break
      }
      let (name, fileType) = HarnessSeededAPI.publicLinkFile(id: fileID)
      let link = Link(
        id: 950 + createsServed, token: "\(createdToken)\(createsServed)", fileID: fileID,
        name: name, fileType: fileType, expiresInHours: 72)
      links = current + [link]
      return (200, #"{"status":"OK","public_share":\#(json(link))}"#)
    }

    private static var initialLinks: [Link] {
      switch mode {
      case .ready, .slow, .failing: boardLinks
      case .journey: boardLinks + [undatedLink]
      case .empty: []
      }
    }

    private static func list(_ current: [Link]) -> (Int, String) {
      listsServed += 1
      if mode == .failing, listsServed == 1 {
        return failure(503, "HARNESS_PUBLIC_SHARE_LIST", "The first link list fails")
      }
      if mode == .journey, listsServed == 1 {
        links = current + [laterLink]
      }
      let rows = current.map(json).joined(separator: ",")
      return (200, #"{"status":"OK","public_shares":[\#(rows)]}"#)
    }

    private static func json(_ link: Link) -> String {
      let expiry = link.expiresInHours.map { #""\#(timestamp(hoursFromNow: $0))""# } ?? "null"
      return #"""
        {"id":\#(link.id),"token":"\#(link.token)","push_token":"push\#(link.id)",\#
        "created_at":"\#(timestamp(hoursFromNow: -1))","expiration_date":\#(expiry),\#
        "owner":{"name":"moviebuff"},\#
        "user_file":{"id":\#(link.fileID),"name":"\#(link.name)","file_type":"\#(link.fileType)"}}
        """#
    }

    private static let formatter: DateFormatter = {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "UTC")
      formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
      return formatter
    }()

    private static func timestamp(hoursFromNow hours: Double) -> String {
      formatter.string(from: Date.now.addingTimeInterval(hours * 3600))
    }

    private static func failure(_ status: Int, _ type: String, _ message: String) -> (Int, String) {
      (
        status,
        #"{"status":"ERROR","status_code":\#(status),"error_type":"\#(type)","message":"\#(message)"}"#
      )
    }
  }
#endif
