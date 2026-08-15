import Darwin
import Dispatch
import Foundation
import PutioHarnessKit

private final class TerminationCoordinator: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.put.harness.lifecycle")
  private let signalQueue = DispatchQueue(label: "io.put.harness.signals")
  private let finished = DispatchSemaphore(value: 0)
  private var sources: [DispatchSourceSignal] = []
  private var status: Int32?

  func install() {
    let signals: [(Int32, Int32)] = [(SIGINT, 130), (SIGTERM, 143)]
    for (signalNumber, exitStatus) in signals {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
      source.setEventHandler { [weak self] in
        guard let self else { return }
        self.queue.async { self.finish(exitStatus) }
      }
      source.resume()
      sources.append(source)
    }
  }

  func run(_ work: @escaping @Sendable () -> Int32) -> Never {
    queue.async {
      let primaryStatus = work()
      self.queue.async { self.finish(primaryStatus) }
    }
    finished.wait()
    exit(status ?? 2)
  }

  private func finish(_ primaryStatus: Int32) {
    guard status == nil else { return }
    do {
      try SimulatorLifecycle.shared.cleanup()
    } catch {
      let warning = HarnessOutput.redact("Simulator cleanup failed: \(error)")
      FileHandle.standardError.write(Data((warning + "\n").utf8))
    }
    status = primaryStatus
    finished.signal()
  }
}

private let coordinator = TerminationCoordinator()
coordinator.install()
coordinator.run {
  do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let invocation = try HarnessArgumentParser.parse(arguments)
    let context = try RepositoryContext.discover()
    let response = try HarnessService(context: context).execute(invocation)
    print(try HarnessOutput.render(response, format: HarnessOutput.format(for: invocation)))
    if case .doctor(let report) = response, report.status != "ok" { return 1 }
    return 0
  } catch {
    let json =
      HarnessOutput.requestedErrorFormat(arguments: Array(CommandLine.arguments.dropFirst()))
      == .json
    FileHandle.standardError.write(Data((HarnessOutput.error(error, json: json) + "\n").utf8))
    return 2
  }
}
