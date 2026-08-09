import Foundation

private struct PutioAuthStatus: Decodable {
  let authenticated: Bool
  let source: String?
  let profile: String?
}

private struct PutioFileList: Decodable {
  struct File: Decodable {
    let id: Int
    let name: String
    let fileType: String
    let parentID: Int

    enum CodingKeys: String, CodingKey {
      case id
      case name
      case fileType = "file_type"
      case parentID = "parent_id"
    }
  }

  let files: [File]
}

private struct PutioCreatedFile: Decodable {
  struct File: Decodable {
    let id: Int
    let name: String
  }

  let file: File?
  let id: Int?
  let name: String?
}

private struct AttachResponse: Decodable {
  let previewURL: String

  enum CodingKeys: String, CodingKey {
    case previewURL = "preview_url"
  }
}

public struct LiveAdapters: Sendable {
  private let context: RepositoryContext
  private let runner: ProcessRunner

  public init(context: RepositoryContext, runner: ProcessRunner = ProcessRunner()) {
    self.context = context
    self.runner = runner
  }

  public func authStatus(profile: String) throws -> HarnessResult {
    _ = try runner.checked(
      "putio", ["describe", "--output", "json"], context: "discover putio CLI contract")
    let output = try runner.checked(
      "putio",
      ["auth", "status", "--profile", profile, "--output", "json"],
      context: "check putio profile \(profile)"
    )
    let status = try JSONDecoder().decode(PutioAuthStatus.self, from: Data(output.stdout.utf8))
    guard status.authenticated else {
      throw HarnessFailure(
        "putio profile \(profile) is not authenticated; run putio auth login --profile \(profile)")
    }
    return HarnessResult(
      command: "auth-status",
      message:
        "profile \(status.profile ?? profile) is authenticated via \(status.source ?? "unknown source")"
    )
  }

  public func provisionFixture(profile: String, name: String) throws -> HarnessResult {
    _ = try authStatus(profile: profile)
    let environment = ["PUTIO_CLI_PROFILE": profile]
    let listOutput = try runner.checked(
      "putio",
      [
        "files", "list",
        "--parent-id", "0",
        "--file-type", "FOLDER",
        "--per-page", "100",
        "--page-all",
        "--output", "json",
      ],
      environment: environment,
      context: "list putio harness fixtures"
    )
    let files = try JSONDecoder().decode(PutioFileList.self, from: Data(listOutput.stdout.utf8))
      .files
    if let existing = files.first(where: {
      $0.name == name && $0.fileType == "FOLDER" && $0.parentID == 0
    }) {
      return HarnessResult(
        command: "live-fixture",
        message:
          "reused root fixture folder \(existing.name) (id \(existing.id)) with profile \(profile)"
      )
    }

    let payload = try jsonString(["name": name, "parent_id": 0] as [String: Any])
    _ = try runner.checked(
      "putio",
      ["files", "mkdir", "--json", payload, "--dry-run", "--output", "json"],
      environment: environment,
      context: "validate putio harness fixture write"
    )
    let createOutput = try runner.checked(
      "putio",
      ["files", "mkdir", "--json", payload, "--output", "json"],
      environment: environment,
      context: "create putio harness fixture"
    )
    let created = try JSONDecoder().decode(
      PutioCreatedFile.self, from: Data(createOutput.stdout.utf8))
    guard let id = created.file?.id ?? created.id else {
      throw HarnessFailure("putio files mkdir returned no fixture id")
    }
    return HarnessResult(
      command: "live-fixture",
      message:
        "created root fixture folder \(created.file?.name ?? created.name ?? name) (id \(id)) with profile \(profile)"
    )
  }

  public func publish(artifact: String, repository: String, pullRequest: Int) throws
    -> HarnessResult
  {
    let artifactURL = URL(fileURLWithPath: artifact, relativeTo: context.root).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: artifactURL.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw HarnessFailure("publish artifact is missing or not a file: \(artifactURL.path)")
    }
    let output = try runner.checked(
      "attach",
      [
        "put", artifactURL.path,
        "--repo", repository,
        "--pr", String(pullRequest),
        "--json",
      ],
      context: "publish proof with attach"
    )
    let response = try JSONDecoder().decode(AttachResponse.self, from: Data(output.stdout.utf8))
    return HarnessResult(
      command: "publish",
      artifacts: [response.previewURL],
      message: "published \(artifactURL.lastPathComponent) to \(response.previewURL)"
    )
  }

  private func jsonString(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let value = String(data: data, encoding: .utf8) else {
      throw HarnessFailure("failed to encode putio CLI payload")
    }
    return value
  }
}
