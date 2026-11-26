import Foundation
import Observation

public typealias PutioFileLookup = @MainActor @Sendable (PutioFileID) async throws -> PutioFileItem

/// Names of the folders search results sit in, looked up once per browser
/// refresh revision. A refresh keeps the shown names until new ones land.
@MainActor
@Observable
public final class PutioFolderNames {
  public private(set) var names: [PutioFileID: String]

  @ObservationIgnored private let lookUp: PutioFileLookup
  @ObservationIgnored private var requested: Set<PutioFileID> = [.root]
  @ObservationIgnored private var revision: UInt64?

  public init(rootName: String, lookUp: @escaping PutioFileLookup) {
    self.lookUp = lookUp
    names = [.root: rootName]
  }

  public func resolve(_ ids: [PutioFileID], revision: UInt64) {
    if revision != self.revision {
      self.revision = revision
      requested = [.root]
    }
    for id in ids where requested.insert(id).inserted {
      Task { [lookUp] in
        let name = try? await lookUp(id).name
        guard revision == self.revision else { return }
        if let name {
          names[id] = name
        } else {
          requested.remove(id)
        }
      }
    }
  }
}
