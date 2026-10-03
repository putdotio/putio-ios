import Foundation
import PutioCore

/// Queue persistence is a JSON document in Application Support. The queue is
/// small, read once at launch, and written on every change; a database would
/// add a dependency for nothing. This is the repository pattern for offline
/// state going forward.
struct PutioOfflineStore: Sendable {
  private struct Document: Codable {
    let version: Int
    var items: [PutioOfflineItem]
    var concurrencyLimit: Int
    /// Originals the user asked put.io to take whose answer is still owed.
    var pendingOriginals: [PutioOfflineRemovalTarget]?
  }

  struct Loaded {
    var items: [PutioOfflineItem]
    var concurrencyLimit: Int
    var pendingOriginals: [PutioOfflineRemovalTarget]
  }

  let directory: URL

  /// Each account keeps its own queue so a later sign-in never sees, plays,
  /// or deletes another account's downloads.
  init(directory: URL? = nil, accountID: Int? = nil) {
    if let directory {
      self.directory = directory
    } else {
      var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "OfflineDownloads", directoryHint: .isDirectory)
      if let accountID {
        base = base.appending(path: "account-\(accountID)", directoryHint: .isDirectory)
      }
      self.directory = base
    }
  }

  private var fileURL: URL { directory.appending(path: "queue.json") }

  static let version = 1

  /// A document that fails to decode is set aside as `queue.corrupt.json`
  /// rather than silently replaced, so stored assets can still be recovered.
  func load() -> Loaded {
    let empty = Loaded(
      items: [], concurrencyLimit: PutioOfflineQueue.defaultConcurrencyLimit, pendingOriginals: [])
    guard let data = try? Data(contentsOf: fileURL) else { return empty }
    guard let document = try? JSONDecoder().decode(Document.self, from: data),
      document.version == Self.version
    else {
      try? FileManager.default.removeItem(at: corruptURL)
      try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
      return empty
    }
    let limit =
      PutioOfflineQueue.concurrencyLimits.contains(document.concurrencyLimit)
      ? document.concurrencyLimit : PutioOfflineQueue.defaultConcurrencyLimit
    return Loaded(
      items: document.items, concurrencyLimit: limit,
      pendingOriginals: document.pendingOriginals ?? [])
  }

  private var corruptURL: URL { directory.appending(path: "queue.corrupt.json") }

  func save(
    items: [PutioOfflineItem], concurrencyLimit: Int,
    pendingOriginals: [PutioOfflineRemovalTarget] = []
  ) throws {
    let document = Document(
      version: Self.version, items: items, concurrencyLimit: concurrencyLimit,
      pendingOriginals: pendingOriginals.isEmpty ? nil : pendingOriginals)
    let data = try JSONEncoder().encode(document)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: fileURL, options: .atomic)
  }

  /// Packages live where AVFoundation put them, outside `directory`, so a
  /// quarantined queue would orphan them. Every location the engine reports
  /// is also kept in `packages.json`, written independently of the queue, so
  /// a purge can still find media the queue no longer lists.
  private var packagesURL: URL { directory.appending(path: "packages.json") }

  func loadPackages() -> Set<String> {
    guard let data = try? Data(contentsOf: packagesURL),
      let paths = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return Set(paths)
  }

  func recordPackages(at relativePaths: some Sequence<String>) throws {
    try updatePackages(recording: relativePaths, forgetting: [])
  }

  func forgetPackage(at relativePath: String) throws {
    try updatePackages(recording: [], forgetting: [relativePath])
  }

  /// One write for both directions; an unchanged record is not rewritten.
  func updatePackages(
    recording: some Sequence<String>, forgetting: some Sequence<String>
  ) throws {
    var packages = loadPackages()
    let before = packages
    packages.formUnion(recording)
    packages.subtract(forgetting)
    guard packages != before else { return }
    try savePackages(packages)
  }

  /// An empty set removes the file so a purge is not undone by a late event
  /// recreating the account directory.
  private func savePackages(_ packages: Set<String>) throws {
    guard !packages.isEmpty else {
      do { try FileManager.default.removeItem(at: packagesURL) } catch CocoaError.fileNoSuchFile {}
      return
    }
    let data = try JSONEncoder().encode(packages.sorted())
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: packagesURL, options: .atomic)
  }
}
