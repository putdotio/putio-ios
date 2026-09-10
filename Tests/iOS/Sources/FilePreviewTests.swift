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
    XCTAssertEqual(PutioUnsupportedFileView.typeName(for: .other("")), "this type of")
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

  func testSessionLossLeavesThePreviewLoadingForTheSignedOutShell() async {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 7), parentID: .root, title: "Poster.png", kind: .image)
    let model = PutioPreviewModel(route: route) { _ in throw PutioRuntimeError.sessionExpired }
    await model.load()
    XCTAssertEqual(model.state, .loading)
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
