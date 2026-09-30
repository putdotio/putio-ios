import Foundation
import Testing

@testable import PutioHarnessKit

/// A fake `putio` on PATH that records each call with the profile and token
/// it saw, and serves a put.io account whose fixture state the test chooses.
private struct FakePutio {
  let root: URL
  let adapters: LiveAdapters

  init(folderExists: Bool, fileExists: Bool, uploadListingLag: Int = 0) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "putio-live-adapters-\(UUID().uuidString.lowercased())")
    let bin = root.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    if folderExists { try Data().write(to: root.appending(path: "folder")) }
    if fileExists { try Data().write(to: root.appending(path: "file")) }
    try Data(String(repeating: "x", count: uploadListingLag).utf8).write(
      to: root.appending(path: "lag"))
    let executable = bin.appending(path: "putio")
    try #"""
    #!/bin/sh
    state="$PUTIO_FAKE_STATE"
    { printf 'CALL profile=%s token=%s\n' "$PUTIO_CLI_PROFILE" "${PUTIO_CLI_TOKEN-unset}"
      printf '%s\n' "$@"; } >> "$state/calls"
    dry=0
    parent=""
    previous=""
    for argument in "$@"; do
      [ "$argument" = "--dry-run" ] && dry=1
      [ "$previous" = "--parent-id" ] && parent="$argument"
      previous="$argument"
    done
    case "$1 $2" in
      "describe --output") echo '{}' ;;
      "auth status") echo '{"authenticated":true,"source":"profile","profile":"devs-auto"}' ;;
      "auth approve") echo '{}' ;;
      "files mkdir")
        [ "$dry" = 0 ] && : > "$state/folder"
        echo '{"file":{"id":77,"name":"putio-ios-harness"}}' ;;
      "files upload")
        [ "$dry" = 0 ] && : > "$state/file"
        echo '{}' ;;
      "files list")
        if [ "$parent" = 0 ]; then
          if [ -f "$state/folder" ]; then
            echo '{"files":[{"id":5,"name":"other","file_type":"FOLDER","parent_id":0},{"id":77,"name":"putio-ios-harness","file_type":"FOLDER","parent_id":0}]}'
          else
            echo '{"files":[{"id":5,"name":"other","file_type":"FOLDER","parent_id":0}]}'
          fi
        elif [ "$parent" = 77 ] && [ -f "$state/file" ] && [ -s "$state/lag" ]; then
          # put.io has accepted the upload but does not list it yet.
          tail -c +2 "$state/lag" > "$state/lag.next" && mv "$state/lag.next" "$state/lag"
          echo '{"files":[]}'
        elif [ "$parent" = 77 ] && [ -f "$state/file" ]; then
          echo '{"files":[{"id":87,"name":"live-fixture.png","file_type":"TEXT","parent_id":77},{"id":88,"name":"live-fixture.png","file_type":"IMAGE","parent_id":77}]}'
        else
          echo '{"files":[]}'
        fi ;;
      *) echo "unexpected putio call: $*" >&2; exit 64 ;;
    esac
    """#.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let runner = ProcessRunner(environment: [
      "PATH": "\(bin.path):\(originalPath)",
      "PUTIO_FAKE_STATE": root.path,
      // An ambient token must never reach the CLI in place of the profile.
      "PUTIO_CLI_TOKEN": "ambient-token-value",
    ])
    adapters = LiveAdapters(
      context: RepositoryContext(root: root), runner: runner, uploadPollInterval: 0.01)
  }

  /// Each call's arguments, after checking that it ran as devs-auto without
  /// the ambient token.
  func calls() throws -> [[String]] {
    let log = root.appending(path: "calls")
    guard FileManager.default.fileExists(atPath: log.path) else { return [] }
    return try String(contentsOf: log, encoding: .utf8)
      .components(separatedBy: "CALL ").dropFirst()
      .map { entry in
        let lines = entry.split(separator: "\n").map(String.init)
        #expect(lines.first == "profile=devs-auto token=unset")
        return Array(lines.dropFirst())
      }
  }

  func writes() throws -> [[String]] {
    try calls().filter {
      ["mkdir", "upload", "approve"].contains($0.dropFirst().first ?? "")
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

struct LiveAdaptersTests {
  @Test func reusesExistingFixtureFolderAndFileWithoutWriting() throws {
    let putio = try FakePutio(folderExists: true, fileExists: true)
    defer { putio.remove() }

    let fixture = try putio.adapters.provisionLiveFixture()

    #expect(fixture.folderID == 77)
    #expect(fixture.fileID == 88)
    #expect(fixture.summary.contains("reused live-fixture.png (id 88)"))
    #expect(try putio.writes().isEmpty)
  }

  @Test func validatesEachFixtureWriteWithDryRunBeforeWriting() throws {
    let putio = try FakePutio(folderExists: false, fileExists: false)
    defer { putio.remove() }

    let fixture = try putio.adapters.provisionLiveFixture()

    #expect(fixture.folderID == 77)
    #expect(fixture.fileID == 88)
    let writes = try putio.writes()
    #expect(
      writes.map { Array($0.prefix(2)) + [$0.contains("--dry-run") ? "dry" : "write"] } == [
        ["files", "mkdir", "dry"], ["files", "mkdir", "write"],
        ["files", "upload", "dry"], ["files", "upload", "write"],
      ])
    let upload = try #require(writes.last)
    let payload = try #require(upload.firstIndex(of: "--json").map { upload[$0 + 1] })
    let request = try #require(
      JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    #expect(request["parent_id"] as? Int == 77)
    #expect(request["file_name"] as? String == "live-fixture.png")
    #expect(
      (request["path"] as? String)?.hasSuffix("Tests/HarnessMedia/previews/runtime-proof-image.png")
        == true)
  }

  @Test func uploadsOnlyTheMissingFileIntoAnExistingFolder() throws {
    let putio = try FakePutio(folderExists: true, fileExists: false)
    defer { putio.remove() }

    let fixture = try putio.adapters.provisionLiveFixture()

    #expect(fixture.fileID == 88)
    #expect(try putio.writes().map { $0[1] } == ["upload", "upload"])
  }

  @Test func waitsForAFreshUploadToBeListed() throws {
    let putio = try FakePutio(folderExists: true, fileExists: false, uploadListingLag: 3)
    defer { putio.remove() }

    let fixture = try putio.adapters.provisionLiveFixture()

    #expect(fixture.fileID == 88)
    #expect(try putio.writes().map { $0[1] } == ["upload", "upload"])
  }

  @Test func approvesACodeAfterADryRun() throws {
    let putio = try FakePutio(folderExists: true, fileExists: true)
    defer { putio.remove() }

    try putio.adapters.approveDeviceCode("AB12CD")

    #expect(
      try putio.calls() == [
        ["auth", "approve", "--json", #"{"code":"AB12CD"}"#, "--dry-run", "--output", "json"],
        ["auth", "approve", "--json", #"{"code":"AB12CD"}"#, "--output", "json"],
      ])
  }

  @Test(arguments: ["", "AB 12", "AB12;rm", "AB12\nCD", "ABC", String(repeating: "A", count: 17)])
  func refusesMalformedCodesBeforeCallingTheCLI(code: String) throws {
    let putio = try FakePutio(folderExists: true, fileExists: true)
    defer { putio.remove() }

    #expect(throws: HarnessFailure.self) { try putio.adapters.approveDeviceCode(code) }
    #expect(try putio.calls().isEmpty)
  }
}

struct LiveSessionContractTests {
  @Test func readsTheCodeTheAppReports() {
    #expect(LiveSessionContract.deviceCode(from: Data("  XK42PQ\n".utf8)) == "XK42PQ")
    #expect(LiveSessionContract.deviceCode(from: Data("XK42 PQ".utf8)) == nil)
    #expect(LiveSessionContract.deviceCode(from: Data("·····".utf8)) == nil)
    #expect(LiveSessionContract.deviceCode(from: Data([0xFF, 0xFE])) == nil)
  }

  @Test func treatsOnlyKnownEndStatesAsRevoked() {
    let revoked = ["no-session", "signed-out", "expired\n"].compactMap {
      LiveSessionContract.outcome(from: Data($0.utf8))
    }
    #expect(revoked.count == 3)
    #expect(revoked.filter(\.isRevoked).count == 3)
    let leaked = ["restore-failed", "sign-out-failed"].compactMap {
      LiveSessionContract.outcome(from: Data($0.utf8))
    }
    #expect(leaked.count == 2)
    #expect(leaked.filter(\.isRevoked).isEmpty)
    #expect(LiveSessionContract.outcome(from: Data("signed-in".utf8)) == nil)
  }
}
