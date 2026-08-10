import Foundation

public struct RepositoryContext: Sendable {
  public let root: URL
  public let derivedData: URL
  public let proofRoot: URL

  public init(root: URL) {
    self.root = root
    derivedData = root.appending(path: "build/DerivedData")
    proofRoot = root.appending(path: "build/proof")
  }

  public static func discover(
    from start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws -> RepositoryContext {
    var candidate = start.standardizedFileURL
    while candidate.path != "/" {
      let manifest = candidate.appending(path: "Project.swift").path
      let mise = candidate.appending(path: "mise.toml").path
      if FileManager.default.fileExists(atPath: manifest),
        FileManager.default.fileExists(atPath: mise)
      {
        return RepositoryContext(root: candidate)
      }
      candidate.deleteLastPathComponent()
    }
    throw HarnessFailure(
      "repository root not found; run from putio-ios or one of its subdirectories")
  }
}

struct RuntimeRecord: Decodable, Sendable {
  let name: String
  let identifier: String
  let version: String
  let platform: String
  let isAvailable: Bool
}

struct RuntimeList: Decodable, Sendable {
  let runtimes: [RuntimeRecord]
}

struct DeviceTypeRecord: Decodable, Sendable {
  let name: String
  let identifier: String
  let productFamily: String
}

struct DeviceTypeList: Decodable, Sendable {
  let devicetypes: [DeviceTypeRecord]
}

struct WorkspaceList: Decodable, Sendable {
  struct Workspace: Decodable, Sendable {
    let schemes: [String]
  }

  let workspace: Workspace
}

func runtimeMatchesSDK(_ runtimeVersion: String, _ sdkVersion: String) -> Bool {
  let runtimeComponents = runtimeVersion.split(separator: ".").prefix(2)
  let sdkComponents = sdkVersion.split(separator: ".").prefix(2)
  return runtimeComponents.elementsEqual(sdkComponents)
}

func requireMatchingProofRevision(expected: String, actual: String) throws {
  guard actual == expected else {
    throw HarnessFailure(
      "proof source revision changed during capture: expected \(expected), found \(actual)")
  }
}
