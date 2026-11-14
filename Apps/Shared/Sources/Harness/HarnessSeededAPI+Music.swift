import Foundation

#if DEBUG
  extension HarnessSeededAPI {
    static let musicFolderID = 3_101
    static let musicFirstTrackID = 3_102
    static let musicTrackID = 3_103
    static let musicLastTrackID = 3_104
    static let singlesFolderID = 3_105
    static let singleMusicFolderID = 3_106
    static let singleTrackID = 3_107

    private static let musicLock = NSLock()
    nonisolated(unsafe) private static var musicPositions: [Int: Int] = [:]
    nonisolated(unsafe) private static var musicFailuresLeft =
      musicArguments.contains(
        "--putio-harness-audio-fails-once") ? 1 : 0

    private static var musicArguments: [String] { ProcessInfo.processInfo.arguments }

    static var usesMusic: Bool { musicArguments.contains("--putio-harness-music") }

    private static var holdsMusicTrack: Bool {
      musicArguments.contains("--putio-harness-audio-held")
    }

    private struct MusicTrack {
      let id: Int
      let name: String
      let parentID: Int
    }

    private static let musicTracks = [
      MusicTrack(
        id: musicFirstTrackID, name: "FFTT Tree Rings October 6, 2026.mp3",
        parentID: musicFolderID),
      MusicTrack(
        id: musicTrackID, name: "FFTT Tree Rings Open Air Session, October 13, 2026.mp3",
        parentID: musicFolderID),
      MusicTrack(
        id: musicLastTrackID, name: "FFTT Tree Rings October 20, 2026.mp3",
        parentID: musicFolderID),
      MusicTrack(
        id: singleTrackID, name: "FFTT Tree Rings Open Air Session, October 13, 2026.mp3",
        parentID: singleMusicFolderID),
    ]

    static var musicRootRows: [String] {
      guard usesMusic else { return [] }
      return [
        musicFolderObject(id: musicFolderID, name: "Music", parentID: 0),
        musicFolderObject(id: singlesFolderID, name: "Singles", parentID: 0),
      ]
    }

    static func holdsMusic(_ url: URL) -> Bool {
      usesMusic && holdsMusicTrack && url.path == "/v2/files/\(musicTrackID)"
    }

    static func musicFixture(_ request: URLRequest, url: URL) -> (Int, String)? {
      guard usesMusic else { return nil }
      let method = request.httpMethod ?? "GET"
      if method == "GET", url.path == "/v2/files/list" {
        return musicListing(url)
      }
      for track in musicTracks {
        switch (method, url.path) {
        case ("GET", "/v2/files/\(track.id)"):
          if track.id == musicTrackID, consumeMusicFailure() {
            return (
              503,
              fixtureError(
                statusCode: 503, type: "HARNESS_AUDIO_UNAVAILABLE", message: "Try again")
            )
          }
          return (
            200,
            #"{"status":"OK","file":"# + musicTrackObject(track) + "}"
          )
        case ("POST", "/v2/files/\(track.id)/start-from/set"):
          return saveMusicPosition(request, fileID: track.id)
        default:
          continue
        }
      }
      return nil
    }

    private static func musicListing(_ url: URL) -> (Int, String)? {
      let parentID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "parent_id" }?.value.flatMap(Int.init)
      switch parentID {
      case musicFolderID:
        return musicPage(
          parent: musicFolderObject(id: musicFolderID, name: "Music", parentID: 0),
          rows: musicRows(in: musicFolderID))
      case singlesFolderID:
        return musicPage(
          parent: musicFolderObject(id: singlesFolderID, name: "Singles", parentID: 0),
          rows: [
            musicFolderObject(id: singleMusicFolderID, name: "Music", parentID: singlesFolderID)
          ])
      case singleMusicFolderID:
        return musicPage(
          parent: musicFolderObject(
            id: singleMusicFolderID, name: "Music", parentID: singlesFolderID),
          rows: musicRows(in: singleMusicFolderID))
      default:
        return nil
      }
    }

    private static func musicRows(in folderID: Int) -> [String] {
      musicTracks.filter { $0.parentID == folderID }.map(musicTrackObject)
    }

    private static func musicPage(parent: String, rows: [String]) -> (Int, String) {
      (
        200,
        """
        {"cursor":"","parent":\(parent),"files":[\(rows.joined(separator: ","))],"total":\(rows.count)}
        """
      )
    }

    private static func musicFolderObject(id: Int, name: String, parentID: Int) -> String {
      """
      {
        "id": \(id),
        "name": "\(name)",
        "file_type": "FOLDER",
        "parent_id": \(parentID),
        "size": 0,
        "created_at": "2026-10-13T10:00:00Z",
        "updated_at": "2026-10-13T10:00:00Z"
      }
      """
    }

    private static func musicTrackObject(_ track: MusicTrack) -> String {
      let position = musicLock.withLock { musicPositions[track.id] ?? 0 }
      return """
        {
          "id": \(track.id),
          "name": "\(track.name)",
          "file_type": "AUDIO",
          "parent_id": \(track.parentID),
          "size": 17772,
          "created_at": "2026-10-13T10:00:00Z",
          "updated_at": "2026-10-13T10:00:00Z",
          "start_from": \(position)
        }
        """
    }

    private static func consumeMusicFailure() -> Bool {
      musicLock.withLock {
        guard musicFailuresLeft > 0 else { return false }
        musicFailuresLeft -= 1
        return true
      }
    }

    private static func saveMusicPosition(_ request: URLRequest, fileID: Int) -> (Int, String) {
      guard
        let body = requestBodyData(request),
        let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let seconds = payload["time"] as? Int
      else {
        return (
          400,
          fixtureError(statusCode: 400, type: "HARNESS_INVALID_REQUEST", message: "Missing time")
        )
      }
      musicLock.withLock { musicPositions[fileID] = seconds }
      return (200, #"{"status":"OK"}"#)
    }
  }
#endif
