import Foundation

public enum PutioFileShareSource: Equatable, Sendable {
  case downloaded
  case fetch(PutioPreviewRoute)

  public init?(item: PutioFileItem, isDownloaded: Bool) {
    guard item.kind != .folder, item.sizeBytes <= PutioPreviewRoute.maximumBytes else {
      return nil
    }
    if isDownloaded {
      self = .downloaded
    } else if let route = PutioFileRoute(item: item).previewRoute {
      self = .fetch(route)
    } else {
      return nil
    }
  }

  public static func dependsOnDownload(_ item: PutioFileItem) -> Bool {
    item.kind != .folder && item.sizeBytes <= PutioPreviewRoute.maximumBytes
      && PutioFileRoute(item: item).previewRoute == nil
  }
}

public struct PutioSharedFile: Equatable, Sendable {
  public let url: URL
  public let isTemporary: Bool

  public init?(local url: URL) {
    guard url.isFileURL else { return nil }
    self.url = url
    isTemporary = false
  }

  private init(temporary url: URL) {
    self.url = url
    isTemporary = true
  }

  public var isPackage: Bool { url.pathExtension.lowercased() == "movpkg" }

  public static func stage(
    named name: String, in directory: URL = .temporaryDirectory,
    write: (URL) async throws -> Void
  ) async throws -> PutioSharedFile {
    let folder =
      directory
      .appending(path: "FileShare", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: fileName(name))
    do {
      try await write(file)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
    return PutioSharedFile(temporary: file)
  }

  public static func stage(
    _ data: Data, named name: String, in directory: URL = .temporaryDirectory
  ) async throws -> PutioSharedFile {
    try await stage(named: name, in: directory) { try data.write(to: $0, options: .atomic) }
  }

  public func discard() {
    guard isTemporary else { return }
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  public static func fileName(_ title: String) -> String {
    let name = title.replacing("/", with: ":")
    return name.isEmpty || name == "." || name == ".." ? "file" : name
  }

  public static func exportName(_ title: String, pathExtension: String) -> String {
    let base = (fileName(title) as NSString).deletingPathExtension
    return "\(base.isEmpty ? "file" : base).\(pathExtension)"
  }
}
