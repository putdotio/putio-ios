import Foundation

public struct HarnessDoctor: Sendable {
  private let context: RepositoryContext
  private let runner: ProcessRunner

  public init(context: RepositoryContext, runner: ProcessRunner = ProcessRunner()) {
    self.context = context
    self.runner = runner
  }

  public func inspect() -> DoctorReport {
    var checks: [DoctorCheck] = []

    checks.append(
      toolCheck(
        "xcodebuild", required: true,
        recovery: "install Xcode 26.x and select it with DEVELOPER_DIR"))
    checks.append(toolCheck("xcrun", required: true, recovery: "install Xcode command-line tools"))
    checks.append(toolCheck("swift", required: true, recovery: "install Xcode 26.x"))
    checks.append(toolCheck("tuist", required: true, recovery: "run mise install"))
    checks.append(toolCheck("git", required: true, recovery: "install Xcode command-line tools"))
    checks.append(
      toolCheck(
        "shasum", required: true,
        recovery: "reinstall Xcode command-line tools or repair the macOS system shasum"))

    if commandExists("xcodebuild") {
      checks.append(xcodeCheck())
    }
    if commandExists("tuist") {
      checks.append(tuistCheck())
    }
    if commandExists("xcrun"), commandExists("xcodebuild") {
      checks.append(contentsOf: runtimeChecks())
    }

    checks.append(workspaceCheck())
    checks.append(
      toolCheck(
        "putio", required: false, recovery: "install the global putio CLI for live-profile checks"))
    checks.append(
      toolCheck("attach", required: false, recovery: "install attach for proof publishing"))
    checks.append(
      DoctorCheck(
        name: "brand-fonts",
        status: .warning,
        required: false,
        detail: "not configured in the scaffold; tracked by issue #126"
      )
    )

    return DoctorReport(checks: checks)
  }

  private func commandExists(_ command: String) -> Bool {
    (try? runner.run("which", [command]).status) == 0
  }

  private func toolCheck(_ command: String, required: Bool, recovery: String) -> DoctorCheck {
    if commandExists(command) {
      return DoctorCheck(
        name: command, status: .ok, required: required, detail: "available on PATH")
    }
    return DoctorCheck(
      name: command,
      status: required ? .failed : .warning,
      required: required,
      detail: "missing; \(recovery)"
    )
  }

  private func xcodeCheck() -> DoctorCheck {
    do {
      let output = try runner.checked("xcodebuild", ["-version"], context: "read Xcode version")
      let firstLine = output.stdout.split(separator: "\n").first.map(String.init) ?? "unknown"
      guard firstLine.hasPrefix("Xcode 26.") else {
        return DoctorCheck(
          name: "xcode-version",
          status: .failed,
          required: true,
          detail: "expected Xcode 26.x, found \(firstLine); select Xcode 26 with DEVELOPER_DIR"
        )
      }
      return DoctorCheck(name: "xcode-version", status: .ok, required: true, detail: firstLine)
    } catch {
      return DoctorCheck(
        name: "xcode-version", status: .failed, required: true, detail: String(describing: error))
    }
  }

  private func tuistCheck() -> DoctorCheck {
    do {
      let actual = try runner.checked("tuist", ["version"], context: "read Tuist version").stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let mise = try String(contentsOf: context.root.appending(path: "mise.toml"), encoding: .utf8)
      let pattern = #"(?m)^tuist\s*=\s*\"([^\"]+)\"\s*$"#
      let regex = try NSRegularExpression(pattern: pattern)
      let range = NSRange(mise.startIndex..., in: mise)
      guard
        let match = regex.firstMatch(in: mise, range: range),
        let versionRange = Range(match.range(at: 1), in: mise)
      else {
        return DoctorCheck(
          name: "tuist-version",
          status: .failed,
          required: true,
          detail: "mise.toml has no Tuist pin"
        )
      }
      let expected = String(mise[versionRange])
      guard actual == expected else {
        return DoctorCheck(
          name: "tuist-version",
          status: .failed,
          required: true,
          detail: "expected \(expected), found \(actual); run mise install"
        )
      }
      return DoctorCheck(name: "tuist-version", status: .ok, required: true, detail: actual)
    } catch {
      return DoctorCheck(
        name: "tuist-version", status: .failed, required: true, detail: String(describing: error))
    }
  }

  private func runtimeChecks() -> [DoctorCheck] {
    do {
      let runtimeOutput = try runner.checked(
        "xcrun",
        ["simctl", "list", "-j", "runtimes"],
        context: "list Simulator runtimes"
      )
      let runtimes = try JSONDecoder().decode(
        RuntimeList.self, from: Data(runtimeOutput.stdout.utf8)
      ).runtimes
      return HarnessPlatform.allCases.map { platform in
        let config = platform.configuration
        do {
          let sdkVersion = try runner.checked(
            "xcodebuild",
            ["-version", "-sdk", config.sdk, "ProductVersion"],
            context: "read \(config.sdk) version"
          ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
          if let runtime = runtimes.first(where: {
            $0.isAvailable && $0.platform == config.runtimePlatform
              && runtimeMatchesSDK($0.version, sdkVersion)
          }) {
            return DoctorCheck(
              name: "\(platform.rawValue)-runtime",
              status: .ok,
              required: true,
              detail: runtime.name
            )
          }
          return DoctorCheck(
            name: "\(platform.rawValue)-runtime",
            status: .failed,
            required: true,
            detail:
              "\(config.runtimePlatform) \(sdkVersion) is missing; run xcodebuild -downloadPlatform \(config.runtimePlatform)"
          )
        } catch {
          return DoctorCheck(
            name: "\(platform.rawValue)-runtime",
            status: .failed,
            required: true,
            detail: String(describing: error)
          )
        }
      }
    } catch {
      return [
        DoctorCheck(
          name: "simulator-runtimes",
          status: .failed,
          required: true,
          detail: String(describing: error)
        )
      ]
    }
  }

  private func workspaceCheck() -> DoctorCheck {
    let workspace = context.root.appending(path: "Putio.xcworkspace")
    guard FileManager.default.fileExists(atPath: workspace.path) else {
      return DoctorCheck(
        name: "generated-schemes",
        status: .failed,
        required: true,
        detail: "Putio.xcworkspace is missing; run mise run generate"
      )
    }

    do {
      let output = try runner.checked(
        "xcodebuild",
        ["-list", "-json", "-workspace", workspace.path],
        currentDirectory: context.root,
        context: "inspect generated workspace"
      )
      let schemes = try JSONDecoder().decode(WorkspaceList.self, from: Data(output.stdout.utf8))
        .workspace.schemes
      let expected = Set(HarnessPlatform.allCases.map(\.configuration.scheme))
      let missing = expected.subtracting(schemes).sorted()
      guard missing.isEmpty else {
        return DoctorCheck(
          name: "generated-schemes",
          status: .failed,
          required: true,
          detail: "missing schemes: \(missing.joined(separator: ", ")); run mise run generate"
        )
      }
      return DoctorCheck(
        name: "generated-schemes",
        status: .ok,
        required: true,
        detail: expected.sorted().joined(separator: ", ")
      )
    } catch {
      return DoctorCheck(
        name: "generated-schemes", status: .failed, required: true,
        detail: String(describing: error))
    }
  }
}
