import Foundation

#if DEBUG
  /// `--putio-harness-shared-items` adds "Items shared with you" to the root,
  /// with two friends' folders and three items inside the first. Each copy
  /// request takes the next answer from `--putio-harness-copy-results`, a
  /// comma list of `done`, `unconfirmed`, `concurrent`, and `too-many`; once
  /// the list runs out, copies finish.
  extension HarnessSeededAPI {
    static let sharedRootID = 520
    static let sharedFriendID = 521
    static let sharedSecondFriendID = 522
    static let sharedHolidayFolderID = 523
    static let sharedVideoID = 524
    static let sharedImageID = 525

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var copyResults = scriptedCopyResults
    nonisolated(unsafe) private static var copies: [Int: SharedCopy] = [:]
    nonisolated(unsafe) private static var nextCopyID = 9_001

    private struct SharedCopy {
      let confirms: Bool
      var checks = 0
    }

    static var usesSharedItems: Bool {
      ProcessInfo.processInfo.arguments.contains("--putio-harness-shared-items")
    }

    private static var scriptedCopyResults: [String] {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "--putio-harness-copy-results"),
        arguments.indices.contains(index + 1)
      else { return [] }
      return arguments[index + 1].split(separator: ",").map(String.init)
    }

    static var sharedRootRow: String {
      sharedFolderObject(
        id: sharedRootID, name: "Items shared with you", parentID: 0, type: "SHARED_ROOT",
        size: 2_836_000_000)
    }

    static func sharedFolderListing(_ parentID: Int) -> (Int, String)? {
      guard usesSharedItems else { return nil }
      switch parentID {
      case sharedRootID:
        return listing(
          parent: sharedRootRow,
          rows: [
            sharedFolderObject(
              id: sharedFriendID, name: "deniz", parentID: sharedRootID, type: "SHARED_FRIEND",
              size: 2_102_400_000),
            sharedFolderObject(
              id: sharedSecondFriendID, name: "selin", parentID: sharedRootID,
              type: "SHARED_FRIEND", size: 734_000_000),
          ])
      case sharedFriendID:
        return listing(
          parent: sharedFolderObject(
            id: sharedFriendID, name: "deniz", parentID: sharedRootID, type: "SHARED_FRIEND",
            size: 2_102_400_000),
          rows: [
            sharedFolderObject(
              id: sharedHolidayFolderID, name: "Holiday 2026", parentID: sharedFriendID,
              type: "REGULAR", size: 1_366_000_000),
            sharedFileObject(
              id: sharedVideoID, name: "Tears.of.Steel.2012.mkv", type: "VIDEO",
              size: 734_000_000),
            sharedFileObject(
              id: sharedImageID, name: "poster.jpg", type: "IMAGE", size: 2_400_000),
          ])
      case sharedSecondFriendID, sharedHolidayFolderID:
        let name = parentID == sharedSecondFriendID ? "selin" : "Holiday 2026"
        return listing(
          parent: sharedFolderObject(
            id: parentID, name: name, parentID: sharedFriendID, type: "REGULAR", size: 0),
          rows: [])
      default:
        return nil
      }
    }

    static func sharedItemsFixture(_ request: URLRequest, path: String) -> (Int, String)? {
      guard usesSharedItems else { return nil }
      if request.httpMethod == "POST", path == "/v2/sharing/clone" {
        return startCopy(request)
      }
      let statusPrefix = "/v2/sharing/clone/"
      if request.httpMethod == "GET", path.hasPrefix(statusPrefix),
        let copyID = Int(path.dropFirst(statusPrefix.count))
      {
        return copyStatus(copyID)
      }
      return nil
    }

    private static func startCopy(_ request: URLRequest) -> (Int, String) {
      guard
        let fileIDs = requestFileIDs(request),
        fileIDs.allSatisfy({ [sharedVideoID, sharedImageID].contains($0) }),
        let parentID = requestPayload(request)?["parent_id"] as? Int, parentID >= 0
      else {
        return (
          400,
          fixtureError(
            statusCode: 400, type: "HARNESS_COPY_INPUT_REQUIRED",
            message: "The copy fixture copies only shared files into a folder")
        )
      }
      return sharedLock.withLock {
        let result = copyResults.isEmpty ? "done" : copyResults.removeFirst()
        switch result {
        case "concurrent":
          return (
            400,
            fixtureError(
              statusCode: 400, type: "SharedFileCloneConcurrentLimit",
              message: "Too many copies at once")
          )
        case "too-many":
          return (
            400,
            fixtureError(
              statusCode: 400, type: "SharedFileCloneTooManyFiles",
              message: "Too many files")
          )
        default:
          let copyID = nextCopyID
          nextCopyID += 1
          copies[copyID] = SharedCopy(confirms: result != "unconfirmed")
          return (200, #"{"status":"OK","id":\#(copyID)}"#)
        }
      }
    }

    /// A confirming copy reports PROCESSING twice, long enough to see that a
    /// second copy cannot start, then DONE.
    private static func copyStatus(_ copyID: Int) -> (Int, String) {
      sharedLock.withLock {
        guard var copy = copies[copyID] else {
          return (
            404,
            fixtureError(statusCode: 404, type: "NotFound", message: "No such copy")
          )
        }
        guard copy.confirms else {
          return (
            503,
            fixtureError(
              statusCode: 503, type: "HARNESS_COPY_STATUS_UNAVAILABLE",
              message: "The copy status never answers")
          )
        }
        copy.checks += 1
        copies[copyID] = copy
        let status = copy.checks > 2 ? "DONE" : "PROCESSING"
        return (200, #"{"status":"OK","shared_file_clone_status":"\#(status)"}"#)
      }
    }

    static func resetSharedItems() {
      sharedLock.withLock {
        copyResults = scriptedCopyResults
        copies = [:]
        nextCopyID = 9_001
      }
    }

    private static func listing(parent: String, rows: [String]) -> (Int, String) {
      (
        200,
        #"{"parent":\#(parent),"files":[\#(rows.joined(separator: ","))],"total":\#(rows.count)}"#
      )
    }

    private static func sharedFolderObject(
      id: Int, name: String, parentID: Int, type: String, size: Int
    ) -> String {
      """
      {"id":\(id),"name":"\(name)","file_type":"FOLDER","folder_type":"\(type)",\
      "is_shared":true,"parent_id":\(parentID),"size":\(size),\
      "created_at":"2026-09-14T10:00:00Z","updated_at":"2026-09-14T10:00:00Z"}
      """
    }

    private static func sharedFileObject(id: Int, name: String, type: String, size: Int) -> String {
      """
      {"id":\(id),"name":"\(name)","file_type":"\(type)","is_shared":true,\
      "parent_id":\(sharedFriendID),"size":\(size),\
      "created_at":"2026-09-14T10:00:00Z","updated_at":"2026-09-14T10:00:00Z"}
      """
    }
  }
#endif
