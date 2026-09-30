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

struct LiveFixture: Equatable, Sendable {
  let folderID: Int
  let fileID: Int
  let summary: String
}

public struct LiveAdapters: Sendable {
  private let context: RepositoryContext
  private let runner: ProcessRunner
  private let environment = ["PUTIO_CLI_PROFILE": LiveFixtureContract.profile]
  private let removedEnvironment: Set<String> = ["PUTIO_CLI_TOKEN"]

  private let uploadPollInterval: TimeInterval

  public init(
    context: RepositoryContext, runner: ProcessRunner = ProcessRunner(),
    uploadPollInterval: TimeInterval = 2
  ) {
    self.context = context
    self.runner = runner
    self.uploadPollInterval = uploadPollInterval
  }

  public func authStatus() throws -> HarnessResult {
    let profile = LiveFixtureContract.profile
    _ = try runner.checked(
      "putio",
      ["describe", "--output", "json"],
      environment: environment,
      removingEnvironment: removedEnvironment,
      context: "discover putio CLI contract"
    )
    let output = try runner.checked(
      "putio",
      ["auth", "status", "--profile", profile, "--output", "json"],
      environment: environment,
      removingEnvironment: removedEnvironment,
      context: "check putio profile \(profile)"
    )
    let status = try JSONDecoder().decode(PutioAuthStatus.self, from: Data(output.stdout.utf8))
    guard status.authenticated, status.source == "profile", status.profile == profile else {
      throw HarnessFailure(
        "putio profile \(profile) is not authenticated from profile storage; run putio auth login --profile \(profile)"
      )
    }
    return HarnessResult(
      command: "auth-status",
      message: "profile \(profile) is authenticated via profile storage"
    )
  }

  public func provisionFixture() throws -> HarnessResult {
    let fixture = try provisionLiveFixture()
    return HarnessResult(command: "live-fixture", message: fixture.summary)
  }

  /// Ensures the root fixture folder and the preview file inside it exist,
  /// reusing both before validating any write with `--dry-run`.
  func provisionLiveFixture() throws -> LiveFixture {
    _ = try authStatus()
    let profile = LiveFixtureContract.profile
    let name = LiveFixtureContract.rootFolder
    let folder: PutioFileList.File
    let folderAction: String
    if let existing = try listFiles(parentID: 0, fileType: "FOLDER").first(where: {
      $0.name == name && $0.fileType == "FOLDER" && $0.parentID == 0
    }) {
      folder = existing
      folderAction = "reused"
    } else {
      let payload = try jsonString(["name": name, "parent_id": 0] as [String: Any])
      _ = try putio(
        ["files", "mkdir", "--json", payload, "--dry-run", "--output", "json"],
        context: "validate putio harness fixture write")
      let createOutput = try putio(
        ["files", "mkdir", "--json", payload, "--output", "json"],
        context: "create putio harness fixture")
      let created = try JSONDecoder().decode(
        PutioCreatedFile.self, from: Data(createOutput.stdout.utf8))
      guard let id = created.file?.id ?? created.id else {
        throw HarnessFailure("putio files mkdir returned no fixture id")
      }
      folder = PutioFileList.File(
        id: id, name: created.file?.name ?? created.name ?? name, fileType: "FOLDER",
        parentID: 0)
      folderAction = "created"
    }

    let fileName = LiveFixtureContract.previewFile
    let fileType = LiveFixtureContract.previewFileType
    func existingFile() throws -> PutioFileList.File? {
      try listFiles(parentID: folder.id, fileType: nil).first {
        $0.name == fileName && $0.fileType == fileType && $0.parentID == folder.id
      }
    }
    var fileAction = "reused"
    var file = try existingFile()
    if file == nil {
      let source = context.root.appending(path: LiveFixtureContract.previewSource)
      let payload = try jsonString(
        ["path": source.path, "parent_id": folder.id, "file_name": fileName] as [String: Any])
      _ = try putio(
        ["files", "upload", "--json", payload, "--dry-run", "--output", "json"],
        context: "validate putio harness fixture upload")
      _ = try putio(
        ["files", "upload", "--json", payload, "--output", "json"],
        context: "upload putio harness fixture file")
      // The listing, not the upload response, proves the file is browsable;
      // put.io lists a fresh upload a few seconds after accepting it.
      for attempt in 0..<15 {
        if attempt > 0 { Thread.sleep(forTimeInterval: uploadPollInterval) }
        file = try existingFile()
        if file != nil { break }
      }
      fileAction = "uploaded"
    }
    guard let file else {
      throw HarnessFailure(
        "putio harness fixture \(fileName) is missing from folder \(folder.id) after upload")
    }
    return LiveFixture(
      folderID: folder.id,
      fileID: file.id,
      summary:
        "\(folderAction) root fixture folder \(folder.name) (id \(folder.id)) and "
        + "\(fileAction) \(file.name) (id \(file.id)) with profile \(profile)"
    )
  }

  /// Approves an activation code shown by a harness-launched app, linking a
  /// new grant for that app to the devs-auto account.
  func approveDeviceCode(_ code: String) throws {
    guard let code = LiveSessionContract.deviceCode(from: Data(code.utf8)) else {
      throw HarnessFailure("refusing to approve a malformed activation code")
    }
    let payload = try jsonString(["code": code])
    _ = try putio(
      ["auth", "approve", "--json", payload, "--dry-run", "--output", "json"],
      context: "validate putio activation code approval")
    _ = try putio(
      ["auth", "approve", "--json", payload, "--output", "json"],
      context: "approve putio activation code")
  }

  private func listFiles(parentID: Int, fileType: String?) throws -> [PutioFileList.File] {
    let output = try putio(
      ["files", "list", "--parent-id", String(parentID)]
        + (fileType.map { ["--file-type", $0] } ?? [])
        + ["--per-page", "100", "--page-all", "--output", "json"],
      context: "list putio harness fixtures")
    return try JSONDecoder().decode(PutioFileList.self, from: Data(output.stdout.utf8)).files
  }

  private func putio(_ arguments: [String], context: String) throws -> ProcessOutput {
    try runner.checked(
      "putio",
      arguments,
      environment: environment,
      removingEnvironment: removedEnvironment,
      context: context
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
