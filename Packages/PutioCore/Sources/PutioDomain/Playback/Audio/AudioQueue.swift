import Foundation

public enum PutioAudioClock {
  public static func text(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = seconds % 3600 / 60
    let remainder = seconds % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
      : String(format: "%d:%02d", minutes, remainder)
  }
}

extension PutioAudioNeighbours {
  public static func stored(_ files: [PutioFileItem], around track: PutioAudioTrack)
    -> PutioAudioNeighbours?
  {
    var queue =
      files
      .filter { $0.kind == .audio && $0.parentID == track.parentID }
      .map { PutioQueuedAudio(id: $0.id, parentID: $0.parentID, name: $0.name) }
    guard !queue.isEmpty else { return nil }
    if !queue.contains(where: { $0.id == track.id }) {
      queue.append(PutioQueuedAudio(id: track.id, parentID: track.parentID, name: track.title))
      queue.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    return PutioAudioNeighbours(of: track.id, in: queue, folderName: nil)
  }
}
