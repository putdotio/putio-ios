import Dispatch
import Foundation
import PutioHarnessKit
import PutioSignalBridge

private final class SimulatorTerminationHandler: @unchecked Sendable {
  private let lock = NSLock()
  private let parkingSemaphore = DispatchSemaphore(value: 0)
  private var isFinished = false
  private var source: DispatchSourceRead?

  func install() throws {
    let descriptor = putio_termination_bridge_install()
    guard descriptor >= 0 else {
      throw HarnessFailure("install termination signal bridge failed")
    }
    let source = DispatchSource.makeReadSource(
      fileDescriptor: descriptor,
      queue: DispatchQueue.global(qos: .userInitiated)
    )
    source.setEventHandler { [weak self] in
      self?.consumeEvent(from: descriptor)
    }
    source.resume()
    self.source = source
  }

  func finish(status: Int32) -> Never {
    if putio_termination_bridge_request_completion(status) != 0 {
      complete(status: status, context: "queue normal completion")
    }
    park()
  }

  private func consumeEvent(from descriptor: Int32) {
    var kind: Int32 = 0
    var value: Int32 = 0
    guard putio_termination_bridge_read(descriptor, &kind, &value) == 0 else {
      complete(status: 2, context: "read termination event")
    }
    switch kind {
    case Int32(PUTIO_TERMINATION_SIGNAL.rawValue):
      complete(status: 128 + value, context: "signal \(value)")
    case Int32(PUTIO_TERMINATION_COMPLETION.rawValue):
      complete(status: value, context: "normal completion")
    default:
      complete(status: 2, context: "unknown termination event")
    }
  }

  private func complete(status: Int32, context: String) -> Never {
    let shouldFinish = lock.withLock {
      guard !isFinished else { return false }
      isFinished = true
      return true
    }
    guard shouldFinish else { park() }
    if putio_termination_bridge_ignore_signals() != 0 {
      let warning = "Disable follow-up termination signals during cleanup failed"
      FileHandle.standardError.write(Data((warning + "\n").utf8))
    }
    do {
      try OwnedSimulatorRegistry.shared.cleanupAll()
    } catch {
      let warning = HarnessOutput.redact("Simulator cleanup during \(context) failed: \(error)")
      FileHandle.standardError.write(Data((warning + "\n").utf8))
    }
    exit(status)
  }

  private func park() -> Never {
    while true {
      parkingSemaphore.wait()
    }
  }
}

private let terminationHandler = SimulatorTerminationHandler()

do {
  try terminationHandler.install()
  let arguments = Array(CommandLine.arguments.dropFirst())
  let invocation = try HarnessArgumentParser.parse(arguments)
  let context = try RepositoryContext.discover()
  let response = try HarnessService(context: context).execute(invocation)
  print(try HarnessOutput.render(response, format: HarnessOutput.format(for: invocation)))
  if case .doctor(let report) = response, report.status != "ok" {
    terminationHandler.finish(status: 1)
  }
  terminationHandler.finish(status: 0)
} catch {
  let json =
    HarnessOutput.requestedErrorFormat(arguments: Array(CommandLine.arguments.dropFirst()))
    == .json
  FileHandle.standardError.write(Data((HarnessOutput.error(error, json: json) + "\n").utf8))
  terminationHandler.finish(status: 2)
}
