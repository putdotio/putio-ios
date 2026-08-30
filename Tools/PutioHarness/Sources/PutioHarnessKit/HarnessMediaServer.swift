import Foundation
import Network

final class HarnessMediaServer: @unchecked Sendable {
  private enum ServerError: Error {
    case failed(String)
    case missingPort
    case startupTimedOut
  }

  private let listener: NWListener
  private let mediaDirectory: URL
  private let queue = DispatchQueue(label: "io.put.harness.media-server")
  private let condition = NSCondition()
  private var startupResult: Result<URL, Error>?

  init(mediaDirectory: URL) throws {
    self.mediaDirectory = mediaDirectory
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
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.serve(connection)
    }
    listener.start(queue: queue)

    condition.lock()
    let deadline = Date().addingTimeInterval(timeout)
    while startupResult == nil, condition.wait(until: deadline) {}
    let result = startupResult
    condition.unlock()
    guard let result else {
      stop()
      throw ServerError.startupTimedOut
    }
    return try result.get()
  }

  func stop() {
    listener.cancel()
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
    let resource: (name: String, contentType: String)
    switch path {
    case "/runtime-proof.m3u8":
      resource = ("runtime-proof.m3u8", "application/vnd.apple.mpegurl")
    case "/runtime-proof-000.ts":
      resource = ("runtime-proof-000.ts", "video/mp2t")
    default:
      send(status: "404 Not Found", headers: [:], body: Data(), over: connection)
      return
    }

    let fileURL = mediaDirectory.appending(path: resource.name)
    guard let fileData = try? Data(contentsOf: fileURL) else {
      send(status: "500 Internal Server Error", headers: [:], body: Data(), over: connection)
      return
    }

    let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
    let response = byteRangeResponse(for: fileData, header: rangeHeader)
    var headers = response.headers
    headers["Content-Type"] = resource.contentType
    headers["Accept-Ranges"] = "bytes"
    send(
      status: response.status,
      headers: headers,
      body: method == "HEAD" ? Data() : response.body,
      declaredLength: response.body.count,
      over: connection
    )
  }

  private func byteRangeResponse(
    for data: Data,
    header: String?
  ) -> (status: String, headers: [String: String], body: Data) {
    guard let header else {
      return ("200 OK", [:], data)
    }
    let value = header.split(separator: ":", maxSplits: 1).last?
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
    connection.send(content: response, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }
}
