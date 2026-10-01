import Foundation
import Network

/// Serves bundled HLS fixtures over loopback HTTP. AVFoundation refuses HLS
/// segments through a resource loader (CoreMedia -12881), so a player item
/// only becomes ready to play when every file arrives over HTTP.
final class LoopbackMediaServer: Sendable {
  private let listener: NWListener
  private let directory: URL
  private let queue = DispatchQueue(label: "loopback-media")

  init(directory: URL) throws {
    self.directory = directory
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    listener = try NWListener(using: parameters, on: .any)
  }

  /// Starts listening and returns the base URL for the served directory.
  func start() async throws -> URL {
    listener.newConnectionHandler = { [self] connection in
      connection.start(queue: queue)
      receive(on: connection, buffer: Data())
    }
    let started = OnceContinuation()
    return try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { [listener] state in
        switch state {
        case .ready:
          guard let port = listener.port?.rawValue,
            let url = URL(string: "http://127.0.0.1:\(port)/")
          else { return }
          started.resume(continuation, with: .success(url))
        case .failed(let error):
          started.resume(continuation, with: .failure(error))
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop() {
    listener.cancel()
  }

  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [self] data, _, isComplete, error in
      var buffer = buffer
      if let data { buffer.append(data) }
      if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
        respond(to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
        receive(on: connection, buffer: Data(buffer[end.upperBound...]))
      } else if isComplete || error != nil {
        connection.cancel()
      } else {
        receive(on: connection, buffer: buffer)
      }
    }
  }

  private func respond(to requestHead: String, on connection: NWConnection) {
    let target = requestHead.split(separator: " ").dropFirst().first ?? "/"
    let name = target.split(separator: "?").first.map(String.init) ?? ""
    guard !name.contains(".."),
      let body = try? Data(contentsOf: directory.appending(path: name))
    else {
      connection.send(
        content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8),
        completion: .idempotent)
      return
    }
    let contentType =
      switch (name as NSString).pathExtension {
      case "m3u8": "application/vnd.apple.mpegurl"
      case "ts": "video/mp2t"
      case "vtt": "text/vtt"
      default: "application/octet-stream"
      }
    let head =
      "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n\r\n"
    connection.send(content: Data(head.utf8) + body, completion: .idempotent)
  }
}

/// Resumes a continuation at most once across listener state updates.
private final class OnceContinuation: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false

  func resume(
    _ continuation: CheckedContinuation<URL, any Error>, with result: Result<URL, any Error>
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard !resumed else { return }
    resumed = true
    continuation.resume(with: result)
  }
}
