import Foundation
import PutioSDK

extension PutioRuntime {
  /// The account's pins, newest first. An account with no config document has none.
  public func pinnedFileIDs() async throws -> [PutioFileID] {
    do {
      return try await performAuthenticatedOperation {
        try await sdk.getConfigValue(
          key: PutioAppConfigKey.pinnedFiles.rawValue, as: PutioPinnedFileIDs.self)
      }.ids
    } catch PutioRuntimeError.notFound {
      return []
    }
  }

  public func setPinnedFileIDs(_ ids: [PutioFileID]) async throws {
    try await setAppConfigValue(.pinnedFiles, ids.map(\.rawValue))
  }
}

struct PutioPinnedFileIDs: Decodable, Sendable {
  let ids: [PutioFileID]

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard !container.decodeNil(), let values = try? container.decode([PinValue].self) else {
      ids = []
      return
    }
    var seen = Set<Int>()
    ids = values.compactMap(\.id).filter { seen.insert($0).inserted }.map(PutioFileID.init)
  }

  private struct PinValue: Decodable {
    let id: Int?

    init(from decoder: Decoder) throws {
      let value = try? decoder.singleValueContainer().decode(Int.self)
      id = value.flatMap { $0 > 0 ? $0 : nil }
    }
  }
}
