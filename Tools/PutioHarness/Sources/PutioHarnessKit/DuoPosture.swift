import Foundation

struct DuoPosture {
  let context: RepositoryContext
  let runner: ProcessRunner
  let fileManager: FileManager

  static let openSteps = [["angle", "180"], ["orientation", "landscape-left"]]

  var source: URL { context.root.appending(path: "Tools/PutioHarness/Guest/DuoPosture.m") }

  func open(simulator identifier: String) throws {
    let directory = fileManager.temporaryDirectory.appending(
      path: "putio-duo-posture-\(UUID().uuidString)")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }
    let tool = directory.appending(path: "duo-posture")
    _ = try runner.checked(
      "xcrun",
      [
        "--sdk", "iphonesimulator", "clang", "-arch", "arm64",
        "-mios-simulator-version-min=27.1", "-fobjc-arc", "-framework", "Foundation",
        "-o", tool.path, source.path,
      ],
      context: "build the iPhone Duo posture tool")
    for step in Self.openSteps {
      let output = try runner.run("xcrun", ["simctl", "spawn", identifier, tool.path] + step)
      guard output.status == 0 else {
        throw HarnessFailure(
          "open the iPhone Duo: `duo-posture \(step.joined(separator: " "))` failed. "
            + "It sends a vendor HID event through the guest's private HIDVirtualEventService, "
            + "the event Device Hub sends; a Simulator runtime update may have changed it.\n"
            + output.combinedOutput)
      }
    }
  }
}
