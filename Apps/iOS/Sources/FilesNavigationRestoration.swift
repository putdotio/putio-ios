import Foundation
import PutioCore

@MainActor
final class PutioFilesNavigationRestoration {
  private struct Snapshot: Codable {
    struct Folder: Codable {
      let id: Int
      let title: String
    }

    let version: Int
    let folders: [Folder]
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func save(path: [PutioFolderRoute], for accountID: Int) {
    guard accountID > 0 else { return }
    guard Self.isValid(path) else {
      clear(accountID: accountID)
      return
    }
    let snapshot = Snapshot(
      version: 1,
      folders: path.map { Snapshot.Folder(id: $0.id.rawValue, title: $0.title) }
    )
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    defaults.set(data, forKey: key(accountID))
  }

  func clear(accountID: Int) {
    defaults.removeObject(forKey: key(accountID))
  }

  func restore(accountID: Int, load: PutioFolderLoad) async -> [PutioFolderRoute] {
    guard accountID > 0, let data = defaults.data(forKey: key(accountID)) else { return [] }
    guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
      snapshot.version == 1
    else {
      clear(accountID: accountID)
      return []
    }
    let savedPath = snapshot.folders.map {
      PutioFolderRoute(id: PutioFileID(rawValue: $0.id), title: $0.title)
    }
    guard Self.isValid(savedPath) else {
      clear(accountID: accountID)
      return []
    }

    var restored: [PutioFolderRoute] = []
    for route in savedPath {
      do {
        try Task.checkCancellation()
        let contents = try await load(route.id)
        try Task.checkCancellation()
        guard defaults.data(forKey: key(accountID)) == data else { return [] }
        guard let folder = contents.folder, folder.id == route.id else { return savedPath }
        guard folder.kind == .folder,
          folder.parentID == (restored.last?.id ?? .root)
        else {
          save(path: restored, for: accountID)
          return restored
        }
        restored.append(PutioFolderRoute(id: folder.id, title: folder.name))
      } catch {
        guard defaults.data(forKey: key(accountID)) == data else { return [] }
        if error as? PutioRuntimeError == .notFound {
          save(path: restored, for: accountID)
          return restored
        }
        // Connectivity and session failures do not prove that a folder vanished.
        return savedPath
      }
    }
    guard defaults.data(forKey: key(accountID)) == data else { return [] }
    save(path: restored, for: accountID)
    return restored
  }

  private static func isValid(_ path: [PutioFolderRoute]) -> Bool {
    path.allSatisfy { $0.id.rawValue > 0 && !$0.title.isEmpty }
      && Set(path.map(\.id)).count == path.count
  }

  private func key(_ accountID: Int) -> String {
    "putio.files.navigation.\(accountID)"
  }
}
