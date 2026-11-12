import PDFKit
import UIKit
import XCTest

@testable import Putio
@testable import PutioCore

@MainActor
final class FilePreviewTests: XCTestCase {
  func testRoutingTableAssignsExactlyOneActionPerKind() {
    let cases: [(PutioFileKind, String)] = [
      (.video, "video"), (.audio, "audio"), (.image, "preview"), (.pdf, "preview"),
      (.text, "preview"),
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
        let expectedKind: PutioPreviewRoute.Kind =
          switch kind {
          case .image: .image
          case .text: .text
          default: .pdf
          }
        XCTAssertEqual(preview.kind, expectedKind)
        XCTAssertEqual(preview.parentID, PutioFileID(rawValue: 9))
      case .unsupported(let unsupported):
        actual = "unsupported"
        XCTAssertEqual(unsupported.item.kind, kind)
      }
      XCTAssertEqual(actual, expected, "\(kind)")
      XCTAssertEqual(route.supportsExternalPlayback, kind == .video || kind == .audio, "\(kind)")
    }
  }

  func testPreviewsOverTheSizeCapCannotBeShown() {
    let cap = PutioPreviewRoute.maximumBytes
    for kind in [PutioFileKind.image, .pdf] {
      let atCap = PutioFileRoute(item: BrowserTestFixtures.item(id: 1, kind: kind, sizeBytes: cap))
      guard case .preview = PutioViewerRoute(opening: atCap.openAction) else {
        return XCTFail("\(kind) at the cap")
      }
      let over = PutioFileRoute(
        item: BrowserTestFixtures.item(id: 2, kind: kind, sizeBytes: cap + 1))
      guard case .preview = over.openAction else { return XCTFail("\(kind) lost its type") }
      XCTAssertEqual(
        PutioViewerRoute(opening: over.openAction),
        .cannotShow(id: over.id, title: over.item.name))
    }
  }

  func testCannotShowRoutesNeverStartADownload() async {
    let archive = BrowserTestFixtures.item(id: 3, kind: .other("ARCHIVE"))
    let oversized = BrowserTestFixtures.item(
      id: 4, kind: .image, sizeBytes: PutioPreviewRoute.maximumBytes + 1)
    for item in [archive, oversized] {
      guard let route = PutioViewerRoute(opening: PutioFileRoute(item: item).openAction),
        case .cannotShow = route
      else {
        return XCTFail("\(item.kind) opened a preview")
      }
      var downloads = 0
      let model = PutioPreviewModel(route: route) { _ in
        downloads += 1
        return Self.pngData()
      }
      XCTAssertEqual(model.state, .failed(.cannotShow))
      await model.load()
      await model.retry()
      XCTAssertEqual(model.state, .failed(.cannotShow))
      XCTAssertEqual(downloads, 0)
    }
  }

  func testImagePreviewDecodesRetriesAndReportsUnreadableData() async throws {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 5), parentID: .root, title: "Poster.png", kind: .image)
    var attempts = 0
    let model = PutioPreviewModel(route: .preview(route)) { _ in
      attempts += 1
      switch attempts {
      case 1: throw PutioRuntimeError.transient
      case 2: return Data("not an image".utf8)
      default: return Self.pngData()
      }
    }
    await model.load()
    XCTAssertEqual(model.state, .failed(.loadFailed))
    await model.retry()
    XCTAssertEqual(model.state, .failed(.cannotShow))
    await model.retry()
    guard case .image(let image) = model.state else { return XCTFail("\(model.state)") }
    XCTAssertEqual(image.size.width * image.scale, 2)
    XCTAssertEqual(image.size.height * image.scale, 2)
    XCTAssertEqual(attempts, 3)
  }

  func testDocumentPreviewRequiresAtLeastOnePageAndShowsNotFoundAsLoadFailed() async throws {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 6), parentID: .root, title: "Doc.pdf", kind: .pdf)
    let notFound = PutioPreviewModel(route: .preview(route)) { _ in
      throw PutioRuntimeError.notFound
    }
    await notFound.load()
    XCTAssertEqual(notFound.state, .failed(.loadFailed))

    let empty = PutioPreviewModel(route: .preview(route)) { _ in Data("%PDF-1.4".utf8) }
    await empty.load()
    XCTAssertEqual(empty.state, .failed(.cannotShow))

    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    let data = renderer.pdfData { context in context.beginPage() }
    let loaded = PutioPreviewModel(route: .preview(route)) { _ in data }
    await loaded.load()
    guard case .document(let document) = loaded.state else { return XCTFail("\(loaded.state)") }
    XCTAssertEqual(document.pageCount, 1)
  }

  func testTextOpensWithoutTheSizeCapBecauseOnlyItsStartIsFetched() {
    let huge = PutioFileRoute(
      item: BrowserTestFixtures.item(
        id: 10, kind: .text, sizeBytes: PutioPreviewRoute.maximumBytes * 4))
    guard case .preview(let route) = PutioViewerRoute(opening: huge.openAction) else {
      return XCTFail("a large text file did not open the viewer")
    }
    XCTAssertEqual(route.kind, .text)
  }

  func testTextPreviewShowsTheStartAndFlagsTruncation() async throws {
    let limit = PutioPreviewRoute.textLimitBytes
    XCTAssertEqual(limit, 250_000)
    let short = try await PutioTextPreview.decode(Data("1\r\nHi\n".utf8), limit: limit)
    XCTAssertEqual(short, PutioTextPreview(text: "1\r\nHi\n", isTruncated: false))

    let bom = try await PutioTextPreview.decode(Data([0xEF, 0xBB, 0xBF] + Array("a".utf8)), limit: 8)
    XCTAssertEqual(bom, PutioTextPreview(text: "a", isTruncated: false))

    let exact = try await PutioTextPreview.decode(Data(repeating: 0x61, count: 8), limit: 8)
    XCTAssertEqual(exact?.isTruncated, false)

    let cutScalar = Data(Array("abcdef".utf8) + [0xE2, 0x80, 0x99, 0x61])
    let truncated = try await PutioTextPreview.decode(cutScalar, limit: 8)
    XCTAssertEqual(truncated, PutioTextPreview(text: "abcdef", isTruncated: true))

    let wholeScalar = Data(Array("abcde".utf8) + [0xE2, 0x80, 0x99, 0x61])
    let kept = try await PutioTextPreview.decode(wholeScalar, limit: 8)
    XCTAssertEqual(kept, PutioTextPreview(text: "abcde\u{2019}", isTruncated: true))
  }

  func testUndecodableTextLandsOnCannotShow() async {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 11), parentID: .root, title: "Notes.txt", kind: .text)
    for body in [Self.pngData(), Data([0x61, 0x00, 0x62]), Data([0xC3, 0x28])] {
      let model = PutioPreviewModel(route: .preview(route)) { _ in body }
      await model.load()
      XCTAssertEqual(model.state, .failed(.cannotShow), "\(Array(body.prefix(4)))")
    }
    let loaded = PutioPreviewModel(route: .preview(route)) { _ in Data("Aye. Grand.".utf8) }
    await loaded.load()
    XCTAssertEqual(loaded.state, .text(PutioTextPreview(text: "Aye. Grand.", isTruncated: false)))
  }

  func testTextDownloadAsksForTheFirstBytesOnly() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PreviewStubURLProtocol.self]
    PreviewStubURLProtocol.ranges.removeAll()

    var url = PreviewStubURLProtocol.url(status: 206, byteCount: 6)
    let ranged = try await PutioPreviewDownloader.downloadPrefix(
      url, byteCount: 6, configuration: configuration)
    XCTAssertEqual(ranged.count, 6)

    url = PreviewStubURLProtocol.url(status: 200, byteCount: 40, declaredLength: 40)
    let ignored = try await PutioPreviewDownloader.downloadPrefix(
      url, byteCount: 6, configuration: configuration)
    XCTAssertEqual(ignored.count, 6)

    url = PreviewStubURLProtocol.url(status: 416, byteCount: 0)
    let empty = try await PutioPreviewDownloader.downloadPrefix(
      url, byteCount: 6, configuration: configuration)
    XCTAssertEqual(empty, Data())

    XCTAssertEqual(PreviewStubURLProtocol.ranges, ["bytes=0-5", "bytes=0-5", "bytes=0-5"])
  }

  func testThePagePillShowsOnlyForMultiPageDocuments() {
    XCTAssertFalse(PutioPDFPagePosition(index: 0, count: 0).showsPill)
    XCTAssertFalse(PutioPDFPagePosition(index: 0, count: 1).showsPill)
    let middle = PutioPDFPagePosition(index: 1, count: 12)
    XCTAssertTrue(middle.showsPill)
    XCTAssertEqual(middle.number, 2)
  }

  func testOversizedPreviewsAreRejectedBeforeDecoding() async {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 8), parentID: .root, title: "Huge.png", kind: .image)
    let model = PutioPreviewModel(route: .preview(route)) { _ in
      throw PutioPreviewTooLargeError()
    }
    await model.load()
    XCTAssertEqual(model.state, .failed(.cannotShow))
  }

  func testReloadCancelsTheInFlightDownload() async {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 9), parentID: .root, title: "Slow.png", kind: .image)
    let started = expectation(description: "first download started")
    let cancelled = expectation(description: "first download observed cancellation")
    var attempts = 0
    let model = PutioPreviewModel(route: .preview(route)) { _ in
      attempts += 1
      if attempts == 1 {
        started.fulfill()
        do {
          try await Task.sleep(for: .seconds(10))
          XCTFail("the first download was not cancelled")
        } catch is CancellationError {
          cancelled.fulfill()
          throw CancellationError()
        }
      }
      return Self.pngData()
    }
    let first = Task { await model.load() }
    defer { first.cancel() }
    await fulfillment(of: [started], timeout: 2)
    await model.retry()
    await fulfillment(of: [cancelled], timeout: 2)
    await first.value
    guard case .image = model.state else { return XCTFail("\(model.state)") }
    XCTAssertEqual(attempts, 2)
  }

  func testSessionLossLeavesThePreviewLoadingForTheSignedOutShell() async {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 7), parentID: .root, title: "Poster.png", kind: .image)
    let model = PutioPreviewModel(route: .preview(route)) { _ in
      throw PutioRuntimeError.sessionExpired
    }
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
    var url = PreviewStubURLProtocol.url(status: 200, byteCount: 32, declaredLength: 32)
    do {
      _ = try await PutioPreviewDownloader.download(url, limit: 16, configuration: configuration)
      XCTFail("declared oversize body was accepted")
    } catch is PutioPreviewTooLargeError {}

    url = PreviewStubURLProtocol.url(status: 200, byteCount: 40)
    do {
      _ = try await PutioPreviewDownloader.download(url, limit: 16, configuration: configuration)
      XCTFail("streamed oversize body was accepted")
    } catch is PutioPreviewTooLargeError {}

    url = PreviewStubURLProtocol.url(status: 200, byteCount: 12)
    let data = try await PutioPreviewDownloader.download(
      url, limit: 16, configuration: configuration)
    XCTAssertEqual(data.count, 12)

    url = PreviewStubURLProtocol.url(status: 200, byteCount: 16)
    let full = try await PutioPreviewDownloader.download(
      url, limit: 16, configuration: configuration)
    XCTAssertEqual(full.count, 16)
    url = PreviewStubURLProtocol.url(status: 200, byteCount: 17)
    do {
      _ = try await PutioPreviewDownloader.download(url, limit: 16, configuration: configuration)
      XCTFail("body one byte over the cap was accepted")
    } catch is PutioPreviewTooLargeError {}

    for (status, expected) in [
      (401, PutioRuntimeError.sessionExpired), (403, .sessionExpired), (404, .notFound),
      (429, .rateLimited), (503, .transient), (418, .unknown),
    ] {
      url = PreviewStubURLProtocol.url(status: status, byteCount: 0)
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
  static func url(status: Int, byteCount: Int, declaredLength: Int? = nil) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "preview.test"
    components.path = "/file"
    components.queryItems = [
      URLQueryItem(name: "status", value: String(status)),
      URLQueryItem(name: "bytes", value: String(byteCount)),
    ]
    if let declaredLength {
      components.queryItems?.append(URLQueryItem(name: "length", value: String(declaredLength)))
    }
    return components.url!
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "preview.test"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  nonisolated(unsafe) static var ranges: [String] = []

  override func startLoading() {
    if let range = request.value(forHTTPHeaderField: "Range") { Self.ranges.append(range) }
    guard let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let status = components.queryItems?.first(where: { $0.name == "status" })?.value.flatMap(
        Int.init),
      let count = components.queryItems?.first(where: { $0.name == "bytes" })?.value.flatMap(
        Int.init),
      count >= 0
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let body = Data(count: count)
    let length = components.queryItems?.first(where: { $0.name == "length" })?.value
    let headers = length.map { ["Content-Length": $0] } ?? [:]
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: nil, headerFields: headers)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
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
