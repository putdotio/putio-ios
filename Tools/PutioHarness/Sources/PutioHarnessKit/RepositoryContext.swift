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

  func requiredXcodeVersion() throws -> String {
    let file = root.appending(path: ".xcode-version")
    let version = try String(contentsOf: file, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !version.isEmpty else { throw HarnessFailure(".xcode-version is empty") }
    return version
  }

  func relativePath(for url: URL) -> String {
    let rootPrefix = root.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPrefix) else { return url.lastPathComponent }
    return String(path.dropFirst(rootPrefix.count))
  }
}

struct RuntimeRecord: Decodable, Sendable {
  let name: String
  let identifier: String
  let version: String
  let platform: String
  let isAvailable: Bool
  let supportedDeviceTypes: [DeviceTypeRecord]

  func deviceType(for family: String) throws -> DeviceTypeRecord {
    guard
      let device = supportedDeviceTypes.first(where: {
        $0.productFamily == family && $0.identifier != foldableDeviceTypeIdentifier
      })
    else {
      throw HarnessFailure("\(name) has no compatible \(family) Simulator device type")
    }
    return device
  }

  var supportsFoldableDevice: Bool {
    platform == "iOS" && versionAtLeast(version, major: 27, minor: 1)
      && supportedDeviceTypes.contains { $0.identifier == foldableDeviceTypeIdentifier }
  }
}

let foldableDeviceTypeIdentifier = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"

func selectSimulator(
  from runtimes: [RuntimeRecord], platform: String, family: String, sdkVersion: String,
  preferredDeviceType: String? = nil
) -> (runtime: RuntimeRecord, deviceType: DeviceTypeRecord)? {
  let matching = runtimes.filter {
    $0.isAvailable && $0.platform == platform && runtimeMatchesSDK($0.version, sdkVersion)
  }
  if let preferredDeviceType {
    for runtime in matching {
      if let deviceType = runtime.supportedDeviceTypes.first(where: {
        $0.name == preferredDeviceType && $0.productFamily == family
      }) {
        return (runtime, deviceType)
      }
    }
  }
  for runtime in matching {
    if let deviceType = try? runtime.deviceType(for: family) {
      return (runtime, deviceType)
    }
  }
  return nil
}

func versionAtLeast(_ version: String, major: Int, minor: Int) -> Bool {
  let components = version.split(separator: ".").compactMap { Int($0) }
  let actual = (components.first ?? 0, components.dropFirst().first ?? 0)
  return actual >= (major, minor)
}

func xcodeVersionMatches(_ versionLine: String, required: String) -> Bool {
  versionLine == "Xcode \(required)" || versionLine.hasPrefix("Xcode \(required).")
}

struct RuntimeList: Decodable, Sendable {
  let runtimes: [RuntimeRecord]
}

struct DeviceTypeRecord: Decodable, Sendable {
  let name: String
  let identifier: String
  let productFamily: String
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
