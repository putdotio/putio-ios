import Foundation
import PutioSDK

extension PutioRuntime {
  public func recentSearches() async throws -> PutioRecentSearches {
    let enabled = try await configValue(.searchHistoryEnabled, as: PutioConfigFlag.self)
    let terms = try await configValue(.searchHistory, as: PutioConfigTerms.self)
    return PutioRecentSearches(enabled: enabled?.value ?? true, terms: terms?.values ?? [])
  }

  public func setRecentSearches(_ terms: [String]) async throws {
    try await setAppConfigValue(.searchHistory, terms)
  }

  private func configValue<Value: Decodable & Sendable>(
    _ key: PutioAppConfigKey, as type: Value.Type
  ) async throws -> Value? {
    do {
      return try await performAuthenticatedOperation {
        try await sdk.getConfigValue(key: key.rawValue, as: Value.self)
      }
    } catch PutioRuntimeError.notFound {
      return nil
    }
  }
}

struct PutioConfigFlag: Decodable, Sendable {
  let value: Bool?

  init(from decoder: Decoder) throws {
    value = try? decoder.singleValueContainer().decode(Bool.self)
  }
}

struct PutioConfigTerms: Decodable, Sendable {
  let values: [String]

  init(from decoder: Decoder) throws {
    let terms = try? decoder.singleValueContainer().decode([Term].self)
    values = terms?.compactMap(\.value) ?? []
  }

  private struct Term: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
      value = try? decoder.singleValueContainer().decode(String.self)
    }
  }
}
