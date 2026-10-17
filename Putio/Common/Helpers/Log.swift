import Foundation
import os

let log = AppLog(logger: Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.put", category: "app"))

/// Writes to the unified log. Messages are private, so a device shows the file
/// names and URLs they carry only to an attached debugger.
struct AppLog: Sendable {
    let logger: Logger

    func verbose(_ message: @autoclosure () -> Any) { write(.debug, message) }
    func debug(_ message: @autoclosure () -> Any) { write(.debug, message) }
    func info(_ message: @autoclosure () -> Any) { write(.info, message) }
    // Notice, where `Logger.warning` would log at error: these are expected
    // conditions, not failures.
    func warning(_ message: @autoclosure () -> Any) { write(.default, message) }
    func error(_ message: @autoclosure () -> Any) { write(.error, message) }

    private func write(_ level: OSLogType, _ message: () -> Any) {
        // os_log builds the string only when the level is enabled, and
        // never keeps it past the call.
        withoutActuallyEscaping(message) { message in
            logger.log(level: level, "\(String(describing: message()), privacy: .private)")
        }
    }
}
