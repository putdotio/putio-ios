import Foundation

public struct PutioVideoErrorEvent: Equatable, Sendable {
  public let uri: URL?
  public let date: Date?

  public init(uri: URL?, date: Date?) {
    self.uri = uri
    self.date = date
  }
}

public struct PutioVideoAudioSwitch: Equatable, Sendable {
  public static let loadWindow: TimeInterval = 10

  public let previous: Int
  public let playlist: URL?
  public let startedAt: Date

  public init(previous: Int, playlist: URL?, startedAt: Date) {
    self.previous = previous
    self.playlist = playlist
    self.startedAt = startedAt
  }

  public func isOver(at date: Date) -> Bool {
    date.timeIntervalSince(startedAt) >= Self.loadWindow
  }

  public func failed(by event: PutioVideoErrorEvent) -> Bool {
    guard let date = event.date, (0..<Self.loadWindow).contains(date.timeIntervalSince(startedAt))
    else { return false }
    guard let uri = event.uri, let playlist else { return false }
    return uri.absoluteURL == playlist.absoluteURL
  }
}
