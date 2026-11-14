import Foundation
import Network

final class HarnessMediaServer: @unchecked Sendable {
  enum ServerError: Error, Equatable {
    case failed(String)
    case missingPort
    case startupTimedOut
    case cancelledBeforeReady
    case waiting(String)
  }

  private let listener: NWListener
  private let mediaDirectory: URL
  private let queue = DispatchQueue(label: "io.put.harness.media-server")
  private let condition = NSCondition()
  private let stopLock = NSLock()
  private let onStop: @Sendable () -> Void
  private let startListener: @Sendable (NWListener, DispatchQueue) throws -> Void
  private var startupResult: Result<URL, Error>?
  private var stopped = false
  private let releaseLock = NSLock()
  private var releasedHolds: Set<String> = []
  private let holdTrickleInterval: DispatchTimeInterval

  init(
    mediaDirectory: URL,
    onStop: @escaping @Sendable () -> Void = {},
    holdTrickleInterval: DispatchTimeInterval = .seconds(1),
    startListener: @escaping @Sendable (NWListener, DispatchQueue) throws -> Void = {
      listener, queue in
      listener.start(queue: queue)
    }
  ) throws {
    self.mediaDirectory = mediaDirectory
    self.onStop = onStop
    self.holdTrickleInterval = holdTrickleInterval
    self.startListener = startListener
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  func start(timeout: TimeInterval = 5) throws -> URL {
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        guard let port = listener.port else {
          resolveStartup(.failure(ServerError.missingPort))
          return
        }
        resolveStartup(
          .success(URL(string: "http://127.0.0.1:\(port.rawValue)/")!)
        )
      case .failed(let error):
        resolveStartup(.failure(ServerError.failed(error.localizedDescription)))
      case .waiting(let error):
        // The listener will not become ready without an external change;
        // fail now instead of burning the startup timeout.
        resolveStartup(.failure(ServerError.waiting(error.localizedDescription)))
      case .cancelled:
        resolveStartup(.failure(ServerError.cancelledBeforeReady))
      case .setup:
        break
      @unknown default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.serve(connection)
    }
    do {
      try startListener(listener, queue)
    } catch {
      stop()
      throw error
    }
    condition.lock()
    let deadline = Date().addingTimeInterval(timeout)
    while startupResult == nil, condition.wait(until: deadline) {}
    let result = startupResult
    condition.unlock()
    do {
      guard let result else { throw ServerError.startupTimedOut }
      return try result.get()
    } catch {
      stop()
      throw error
    }
  }

  private var isStopped: Bool {
    stopLock.lock()
    defer { stopLock.unlock() }
    return stopped
  }

  func stop() {
    stopLock.lock()
    guard !stopped else {
      stopLock.unlock()
      return
    }
    stopped = true
    stopLock.unlock()
    listener.cancel()
    onStop()
  }

  private func resolveStartup(_ result: Result<URL, Error>) {
    condition.lock()
    if startupResult == nil {
      startupResult = result
      condition.broadcast()
    }
    condition.unlock()
  }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    receiveRequest(from: connection, buffer: Data())
  }

  private func receiveRequest(from connection: NWConnection, buffer: Data) {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 8_192
    ) { [weak self] data, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }
      var request = buffer
      if let data { request.append(data) }
      if request.range(of: Data("\r\n\r\n".utf8)) != nil {
        sendResponse(for: request, over: connection)
      } else if isComplete || error != nil || request.count >= 8_192 {
        send(status: "400 Bad Request", headers: [:], body: Data(), over: connection)
      } else {
        receiveRequest(from: connection, buffer: request)
      }
    }
  }

  private func sendResponse(for request: Data, over connection: NWConnection) {
    let requestText = String(decoding: request, as: UTF8.self)
    let lines = requestText.components(separatedBy: "\r\n")
    let requestLine = lines.first?.split(separator: " ") ?? []
    guard requestLine.count >= 2 else {
      send(status: "400 Bad Request", headers: [:], body: Data(), over: connection)
      return
    }
    let method = String(requestLine[0])
    guard method == "GET" || method == "HEAD" else {
      send(
        status: "405 Method Not Allowed",
        headers: ["Allow": "GET, HEAD"],
        body: Data(),
        over: connection
      )
      return
    }

    let path = String(requestLine[1])
    guard !path.hasPrefix("/forbidden/") else {
      send(status: "403 Forbidden", headers: [:], body: Data(), over: connection)
      return
    }
    if let token = Self.releasedHoldToken(path: path) {
      releaseLock.lock()
      releasedHolds.insert(token)
      releaseLock.unlock()
      send(status: "204 No Content", headers: [:], body: Data(), over: connection)
      return
    }
    var holdToken: String?
    let resource: (name: String, contentType: String)
    switch path {
    case "/runtime-proof.m3u8":
      resource = ("runtime-proof.m3u8", "application/vnd.apple.mpegurl")
    case "/runtime-proof-000.ts":
      resource = ("runtime-proof-000.ts", "video/mp2t")
    case "/runtime-proof-audio.m4a":
      resource = ("runtime-proof-audio.m4a", "audio/mp4")
    case "/runtime-proof-image.png":
      resource = ("runtime-proof-image.png", "image/png")
    case "/runtime-proof-document.pdf":
      resource = ("runtime-proof-document.pdf", "application/pdf")
    case "/runtime-proof-subtitles.srt":
      resource = ("runtime-proof-subtitles.srt", "application/x-subrip")
    case "/runtime-proof-long.srt":
      resource = ("runtime-proof-long.srt", "application/x-subrip")
    default:
      if let held = Self.heldResource(path: path) {
        resource = (held.name, held.contentType)
        holdToken = held.holdToken
        break
      }
      // The multi-audio HLS asset is a directory of playlists and segments
      // that reference each other by relative name.
      guard let multi = Self.multiAudioResource(path: path) else {
        send(status: "404 Not Found", headers: [:], body: Data(), over: connection)
        return
      }
      resource = multi
    }

    let fileURL = mediaDirectory.appending(path: resource.name)
    guard let fileData = try? Data(contentsOf: fileURL) else {
      send(status: "404 Not Found", headers: [:], body: Data(), over: connection)
      return
    }

    let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
    let response = byteRangeResponse(for: fileData, header: rangeHeader)
    var headers = response.headers
    headers["Content-Type"] = resource.contentType
    headers["Accept-Ranges"] = "bytes"
    if let holdToken, method == "GET", response.body.count > 1, !isReleased(holdToken) {
      sendHeld(
        status: response.status, headers: headers, body: response.body, token: holdToken,
        over: connection)
      return
    }
    send(
      status: response.status,
      headers: headers,
      body: method == "HEAD" ? Data() : response.body,
      declaredLength: response.body.count,
      over: connection
    )
  }

  /// `/multi-audio/<name>` where name is a playlist, segment, or WebVTT file of the fixture.
  static func multiAudioResource(path: String) -> (name: String, contentType: String)? {
    let prefix = "/multi-audio/"
    guard path.hasPrefix(prefix) else { return nil }
    let name = String(path.dropFirst(prefix.count))
    guard !name.isEmpty, !name.contains("/"), !name.contains(".."),
      name.hasPrefix("multi-") || name == "runtime-proof-multi.m3u8"
    else { return nil }
    if name.hasSuffix(".m3u8") { return ("multi-audio/\(name)", "application/vnd.apple.mpegurl") }
    if name.hasSuffix(".ts") { return ("multi-audio/\(name)", "video/mp2t") }
    if name.hasSuffix(".vtt") { return ("multi-audio/\(name)", "text/vtt") }
    return nil
  }

  static func releasedHoldToken(path: String) -> String? {
    let prefix = "/release/"
    guard path.hasPrefix(prefix) else { return nil }
    let token = String(path.dropFirst(prefix.count))
    return isHoldToken(token) ? token : nil
  }

  static func heldResource(path: String)
    -> (name: String, contentType: String, holdToken: String?)?
  {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 5, parts[0].isEmpty, parts[1] == "held" else { return nil }
    let token = String(parts[2])
    let name = String(parts[4])
    guard isHoldToken(token) else { return nil }
    let heldSegment: String
    switch parts[3] {
    case "start": heldSegment = "held-000.ts"
    case "middle": heldSegment = "held-005.ts"
    default: return nil
    }
    if name == "held.m3u8" {
      return ("held/held.m3u8", "application/vnd.apple.mpegurl", nil)
    }
    guard (0..<10).map({ "held-00\($0).ts" }).contains(name) else { return nil }
    return ("held/\(name)", "video/mp2t", name == heldSegment ? token : nil)
  }

  private static func isHoldToken(_ token: String) -> Bool {
    !token.isEmpty && token.count <= 64
      && token.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "-"
      }
  }

  private func isReleased(_ token: String) -> Bool {
    releaseLock.lock()
    defer { releaseLock.unlock() }
    return releasedHolds.contains(token)
  }

  private func sendHeld(
    status: String, headers: [String: String], body: Data, token: String,
    over connection: NWConnection
  ) {
    var responseHeaders = headers
    responseHeaders["Content-Length"] = String(body.count)
    responseHeaders["Cache-Control"] = "no-store"
    responseHeaders["Connection"] = "close"
    let headerText =
      (["HTTP/1.1 \(status)"]
      + responseHeaders.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }
      + ["", ""])
      .joined(separator: "\r\n")
    connection.send(
      content: Data(headerText.utf8),
      completion: .contentProcessed { [weak self] error in
        guard error == nil else { return connection.cancel() }
        self?.trickle(body, sent: 0, token: token, over: connection)
      })
  }

  private func trickle(_ body: Data, sent: Int, token: String, over connection: NWConnection) {
    guard case .ready = connection.state, !isStopped else { return connection.cancel() }
    if isReleased(token) {
      connection.send(
        content: body.subdata(in: sent..<body.count),
        completion: .contentProcessed { _ in connection.cancel() })
      return
    }
    let packet = 188
    let next = min(sent + packet, body.count - 1)
    connection.send(
      content: body.subdata(in: sent..<next),
      completion: .contentProcessed { [weak self] error in
        guard let self, error == nil else { return connection.cancel() }
        queue.asyncAfter(deadline: .now() + holdTrickleInterval) { [weak self] in
          guard let self else { return connection.cancel() }
          trickle(body, sent: next, token: token, over: connection)
        }
      })
  }

  private func byteRangeResponse(
    for data: Data,
    header: String?
  ) -> (status: String, headers: [String: String], body: Data) {
    guard let header else {
      return ("200 OK", [:], data)
    }
    let value =
      header.split(separator: ":", maxSplits: 1).last?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard value.hasPrefix("bytes="),
      let dash = value.firstIndex(of: "-"),
      let start = Int(value[value.index(value.startIndex, offsetBy: 6)..<dash])
    else {
      return (
        "416 Range Not Satisfiable",
        ["Content-Range": "bytes */\(data.count)"],
        Data()
      )
    }
    let endText = value[value.index(after: dash)...]
    let requestedEnd = Int(endText) ?? (data.count - 1)
    guard start >= 0, start < data.count, requestedEnd >= start else {
      return (
        "416 Range Not Satisfiable",
        ["Content-Range": "bytes */\(data.count)"],
        Data()
      )
    }
    let end = min(requestedEnd, data.count - 1)
    return (
      "206 Partial Content",
      ["Content-Range": "bytes \(start)-\(end)/\(data.count)"],
      data.subdata(in: start..<(end + 1))
    )
  }

  private func send(
    status: String,
    headers: [String: String],
    body: Data,
    declaredLength: Int? = nil,
    over connection: NWConnection
  ) {
    var responseHeaders = headers
    responseHeaders["Content-Length"] = String(declaredLength ?? body.count)
    responseHeaders["Cache-Control"] = "no-store"
    responseHeaders["Connection"] = "close"
    let headerText =
      (["HTTP/1.1 \(status)"]
      + responseHeaders.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }
      + ["", ""])
      .joined(separator: "\r\n")
    var response = Data(headerText.utf8)
    response.append(body)
    connection.send(
      content: response,
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }
}
