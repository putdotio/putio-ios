import Foundation

/// The type chips above search results. The search sends the filter's types;
/// Subtitles has no put.io type, so it searches everything and keeps subtitle
/// files, as Android does.
public enum PutioFileSearchFilter: String, CaseIterable, Hashable, Sendable {
  case all
  case folders
  case videos
  case audio
  case images
  case documents
  case subtitles

  private static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "sub", "smi"]

  public func accepts(_ item: PutioFileItem) -> Bool {
    switch self {
    case .all: true
    case .folders: item.kind == .folder
    case .videos: item.kind == .video
    case .audio: item.kind == .audio
    case .images: item.kind == .image
    case .documents: item.kind == .pdf || item.kind == .text
    case .subtitles:
      item.kind != .folder
        && Self.subtitleExtensions.contains(
          (item.name as NSString).pathExtension.lowercased())
    }
  }
}

/// Search results split into the Folders and Files groups, each in result order.
public struct PutioFileSearchGroups: Equatable, Sendable {
  public let folders: [PutioFileItem]
  public let files: [PutioFileItem]

  public init(_ items: [PutioFileItem]) {
    folders = items.filter { $0.kind == .folder }
    files = items.filter { $0.kind != .folder }
  }

  /// Parent folders the rows name, in first-seen order.
  public var parentIDs: [PutioFileID] {
    var seen = Set<PutioFileID>()
    return (folders + files).map(\.parentID).filter { seen.insert($0).inserted }
  }
}
