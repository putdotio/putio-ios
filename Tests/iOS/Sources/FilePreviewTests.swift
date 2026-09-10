import PDFKit
import PutioCore
import UIKit
import XCTest

@testable import Putio

@MainActor
final class FilePreviewTests: XCTestCase {
  func testRoutingTableAssignsExactlyOneActionPerKind() {
    let cases: [(PutioFileKind, String)] = [
      (.video, "video"), (.audio, "audio"), (.image, "preview"), (.pdf, "preview"),
      (.other("ARCHIVE"), "unsupported"), (.other(""), "unsupported"),
    ]
    for (kind, expected) in cases {
      let route = PutioFileRoute(item: BrowserTestFixtures.item(id: 1, parentID: 9, kind: kind))
      let actual: String
      switch route.openAction {
      case .video(let video):
        actual = "video"
        XCTAssertEqual(video.parentID, PutioFileID(rawValue: 9))
      case .audio: actual = "audio"
      case .preview(let preview):
        actual = "preview"
        XCTAssertEqual(preview.kind, kind == .image ? .image : .pdf)
        XCTAssertEqual(preview.parentID, PutioFileID(rawValue: 9))
      case .unsupported(let unsupported):
        actual = "unsupported"
        XCTAssertEqual(unsupported.item.kind, kind)
      }
      XCTAssertEqual(actual, expected, "\(kind)")
      XCTAssertEqual(route.supportsExternalPlayback, kind == .video || kind == .audio, "\(kind)")
    }
  }

  func testUnsupportedTypeNamesReadNaturally() {
    XCTAssertEqual(PutioUnsupportedFileView.typeName(for: .other("ARCHIVE")), "archive")
    XCTAssertEqual(PutioUnsupportedFileView.typeName(for: .other("DISK_IMAGE")), "disk image")
    XCTAssertNil(PutioUnsupportedFileView.typeName(for: .other("")))
    XCTAssertNil(PutioUnsupportedFileView.typeName(for: .other("  ")))
  }

  func testImagePreviewDecodesRetriesAndReportsUnreadableData() async throws {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 5), parentID: .root, title: "Poster.png", kind: .image)
    var attempts = 0
    let model = PutioPreviewModel(route: route) { _ in
      attempts += 1
      switch attempts {
      case 1: throw PutioRuntimeError.transient
      case 2: return Data("not an image".utf8)
      default: return Self.pngData()
      }
    }
    await model.load()
    guard case .failed(let failure) = model.state else { return XCTFail("\(model.state)") }
    XCTAssertEqual(failure.kind, .transient)
    XCTAssertEqual(failure.title, "Could not open image")
    await model.retry()
    guard case .failed(let unreadable) = model.state else { return XCTFail("\(model.state)") }
    XCTAssertEqual(unreadable.kind, .unreadable)
    XCTAssertEqual(unreadable.title, "Could not display image")
    await model.retry()
    guard case .image(let image) = model.state else { return XCTFail("\(model.state)") }
    XCTAssertEqual(image.size.width * image.scale, 2)
    XCTAssertEqual(image.size.height * image.scale, 2)
    XCTAssertEqual(attempts, 3)
  }

  func testDocumentPreviewRequiresAtLeastOnePageAndMapsNotFound() async throws {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 6), parentID: .root, title: "Doc.pdf", kind: .pdf)
    let notFound = PutioPreviewModel(route: route) { _ in throw PutioRuntimeError.notFound }
    await notFound.load()
    guard case .failed(let failure) = notFound.state else { return XCTFail("\(notFound.state)") }
    XCTAssertEqual(failure.kind, .notFound)
    XCTAssertEqual(failure.title, "Document not found")

    let empty = PutioPreviewModel(route: route) { _ in Data("%PDF-1.4".utf8) }
    await empty.load()
    guard case .failed(let unreadable) = empty.state else { return XCTFail("\(empty.state)") }
    XCTAssertEqual(unreadable.kind, .unreadable)

    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    let data = renderer.pdfData { context in context.beginPage() }
    let loaded = PutioPreviewModel(route: route) { _ in data }
    await loaded.load()
    guard case .document(let document) = loaded.state else { return XCTFail("\(loaded.state)") }
    XCTAssertEqual(document.pageCount, 1)
  }

  func testOversizedPreviewsAreRejectedBeforeDecoding() async {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 8), parentID: .root, title: "Huge.png", kind: .image)
    let model = PutioPreviewModel(route: route) { _ in throw PutioPreviewTooLargeError() }
    await model.load()
    guard case .failed(let failure) = model.state else { return XCTFail("\(model.state)") }
    XCTAssertEqual(failure.kind, .tooLarge)
    XCTAssertEqual(failure.title, "Image too large to preview")
  }

  func testReloadCancelsTheInFlightDownload() async {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 9), parentID: .root, title: "Slow.png", kind: .image)
    var attempts = 0
    let model = PutioPreviewModel(route: route) { _ in
      attempts += 1
      if attempts == 1 {
        try await Task.sleep(for: .seconds(10))
        XCTFail("the first download was not cancelled")
      }
      return Self.pngData()
    }
    let first = Task { await model.load() }
    await Task.yield()
    await model.retry()
    await first.value
    guard case .image = model.state else { return XCTFail("\(model.state)") }
    XCTAssertEqual(attempts, 2)
  }

  func testSessionLossLeavesThePreviewLoadingForTheSignedOutShell() async {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 7), parentID: .root, title: "Poster.png", kind: .image)
    let model = PutioPreviewModel(route: route) { _ in throw PutioRuntimeError.sessionExpired }
    await model.load()
    XCTAssertEqual(model.state, .loading)
  }

  func testLargeImagesAreDownsampledToTheDisplayCap() async throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let wide = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 30), format: format)
      .pngData { context in
        UIColor.blue.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 30))
      }
    let image = try await PutioPreviewModel.decodeImage(wide, maximumPixels: 300)
    let decoded = try XCTUnwrap(image)
    XCTAssertEqual(decoded.size.width * decoded.scale, 300)
    XCTAssertEqual(decoded.size.height * decoded.scale, 10)
  }

  func testDownloaderEnforcesTheByteCapAndMapsStatuses() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PreviewStubURLProtocol.self]
    let url = URL(string: "https://preview.test/file")!

    PreviewStubURLProtocol.response = (200, ["Content-Length": "32"], Data(count: 32))
    do {
      _ = try await PutioPreviewDownloader.download(url, limit: 16, configuration: configuration)
      XCTFail("declared oversize body was accepted")
    } catch is PutioPreviewTooLargeError {}

    PreviewStubURLProtocol.response = (200, [:], Data(count: 40))
    do {
      _ = try await PutioPreviewDownloader.download(url, limit: 16, configuration: configuration)
      XCTFail("streamed oversize body was accepted")
    } catch is PutioPreviewTooLargeError {}

    PreviewStubURLProtocol.response = (200, [:], Data(count: 12))
    let data = try await PutioPreviewDownloader.download(
      url, limit: 16, configuration: configuration)
    XCTAssertEqual(data.count, 12)

    // Exactly at the cap is allowed; one byte over is rejected.
    PreviewStubURLProtocol.response = (200, [:], Data(count: 16))
    let full = try await PutioPreviewDownloader.download(
      url, limit: 16, configuration: configuration)
    XCTAssertEqual(full.count, 16)
    PreviewStubURLProtocol.response = (200, [:], Data(count: 17))
    do {
      _ = try await PutioPreviewDownloader.download(url, limit: 16, configuration: configuration)
      XCTFail("body one byte over the cap was accepted")
    } catch is PutioPreviewTooLargeError {}

    for (status, expected) in [
      (401, PutioRuntimeError.sessionExpired), (403, .sessionExpired), (404, .notFound),
      (429, .rateLimited), (503, .transient), (418, .unknown),
    ] {
      PreviewStubURLProtocol.response = (status, [:], Data())
      do {
        _ = try await PutioPreviewDownloader.download(
          url, limit: 16, configuration: configuration)
        XCTFail("\(status) was accepted")
      } catch let error as PutioRuntimeError {
        XCTAssertEqual(error, expected, "\(status)")
      }
    }
  }

  private static func pngData() -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format)
    return renderer.pngData { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
  }
}

private final class PreviewStubURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var response: (Int, [String: String], Data) = (200, [:], Data())

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let (status, headers, body) = Self.response
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    // Deliver in small chunks so the streamed cap trips mid-body.
    var offset = 0
    while offset < body.count {
      let end = min(offset + 8, body.count)
      client?.urlProtocol(self, didLoad: body[offset..<end])
      offset = end
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
