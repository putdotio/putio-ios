import PDFKit
import UIKit
import UniformTypeIdentifiers
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
      let model = PutioPreviewModel(route: route) { _, _ in
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
    let model = PutioPreviewModel(route: .preview(route)) { _, _ in
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
    let notFound = PutioPreviewModel(route: .preview(route)) { _, _ in
      throw PutioRuntimeError.notFound
    }
    await notFound.load()
    XCTAssertEqual(notFound.state, .failed(.loadFailed))

    let empty = PutioPreviewModel(route: .preview(route)) { _, _ in Data("%PDF-1.4".utf8) }
    await empty.load()
    XCTAssertEqual(empty.state, .failed(.cannotShow))

    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    let data = renderer.pdfData { context in context.beginPage() }
    let loaded = PutioPreviewModel(route: .preview(route)) { _, _ in data }
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

    let bom = try await PutioTextPreview.decode(
      Data([0xEF, 0xBB, 0xBF] + Array("a".utf8)), limit: 8)
    XCTAssertEqual(bom, PutioTextPreview(text: "a", isTruncated: false))

    let exact = try await PutioTextPreview.decode(Data(repeating: 0x61, count: 8), limit: 8)
    XCTAssertEqual(exact?.isTruncated, false)

    let cutScalar = Data(Array("abcdef".utf8) + [0xE2, 0x80, 0x99, 0x61])
    let truncated = try await PutioTextPreview.decode(cutScalar, limit: 8)
    XCTAssertEqual(truncated, PutioTextPreview(text: "abcdef", isTruncated: true))

    let wholeScalar = Data(Array("abcde".utf8) + [0xE2, 0x80, 0x99, 0x61])
    let kept = try await PutioTextPreview.decode(wholeScalar, limit: 8)
    XCTAssertEqual(kept, PutioTextPreview(text: "abcde\u{2019}", isTruncated: true))

    let latin1 = try await PutioTextPreview.decode(Data([0x43, 0x61, 0x66, 0xE9]), limit: limit)
    XCTAssertEqual(latin1, PutioTextPreview(text: "Caf\u{E9}", isTruncated: false))
  }

  func testVoiceOverCanCopyTheWholeTextPreview() throws {
    let text = "1\n00:00:02,000 --> 00:00:05,000\nPreviously on Blue Lights.\n"
    let container = PutioTextPreviewContainer()
    container.show(
      PutioTextPreview(text: text, isTruncated: false),
      truncationNotice: PutioTextPreviewNotice(text: "", figure: ""))
    let element = try XCTUnwrap(container.accessibilityElements?.first as? UIAccessibilityElement)
    let copy = try XCTUnwrap(element.accessibilityCustomActions?.first)
    UIPasteboard.general.string = ""

    XCTAssertEqual(copy.actionHandler?(copy), true)
    XCTAssertEqual(UIPasteboard.general.string, text)
  }

  func testUndecodableTextLandsOnCannotShow() async {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 11), parentID: .root, title: "Notes.txt", kind: .text)
    for body in [Self.pngData(), Data([0x61, 0x00, 0x62]), Data([0xFF, 0xFE, 0x61, 0x00])] {
      let model = PutioPreviewModel(route: .preview(route)) { _, _ in body }
      await model.load()
      XCTAssertEqual(model.state, .failed(.cannotShow), "\(Array(body.prefix(4)))")
    }
    let loaded = PutioPreviewModel(route: .preview(route)) { _, _ in Data("Aye. Grand.".utf8) }
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

  func testShareHandsOverTheLoadedBytesAsALocalFileAndRemovesItOnClose() async throws {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 12), parentID: .root, title: "Poster.png", kind: .image)
    let bytes = Self.pngData()
    var extents: [PutioPreviewExtent] = []
    let model = PutioPreviewModel(route: .preview(route)) { _, extent in
      extents.append(extent)
      return bytes
    }
    XCTAssertNil(model.share, "Share is enabled while loading")
    await model.load()
    let share = try XCTUnwrap(model.share)
    XCTAssertEqual(share.name, "Poster.png")

    let file = try await share.export()
    XCTAssertTrue(file.isFileURL)
    XCTAssertTrue(
      file.standardizedFileURL.path.hasPrefix(URL.temporaryDirectory.standardizedFileURL.path),
      "\(file.path) is outside the temporary directory")
    XCTAssertFalse(file.absoluteString.contains("put.io"))
    XCTAssertEqual(file.lastPathComponent, "Poster.png")
    XCTAssertEqual(try Data(contentsOf: file), bytes)
    let again = try await share.export()
    XCTAssertEqual(again, file)
    XCTAssertEqual(extents, [.preview])

    model.cancel()
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testShareFetchesTheWholeTextFileUpToTheCap() async throws {
    let limit = PutioPreviewRoute.textLimitBytes
    let whole = Data(repeating: 0x61, count: limit + 4_000)
    var extents: [PutioPreviewExtent] = []
    let download: PutioPreviewDownload = { _, extent in
      extents.append(extent)
      return extent == .whole ? whole : whole.prefix(limit + 1)
    }
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 13), parentID: .root, title: "Blue.Lights.S04.en.srt", kind: .text)
    let model = PutioPreviewModel(route: .preview(route), download: download)
    await model.load()
    guard case .text(let text) = model.state, text.isTruncated else {
      return XCTFail("\(model.state)")
    }
    let file = try await XCTUnwrap(model.share).export()
    XCTAssertEqual(try Data(contentsOf: file), whole)
    XCTAssertEqual(extents, [.preview, .whole])
    model.cancel()

    let oversized = PutioPreviewRoute(
      id: PutioFileID(rawValue: 14), parentID: .root, title: "Huge.srt", kind: .text,
      exceedsSizeCap: true)
    let capped = PutioPreviewModel(route: .preview(oversized), download: download)
    await capped.load()
    guard case .text = capped.state else { return XCTFail("\(capped.state)") }
    XCTAssertNil(capped.share, "Share is enabled above the size cap")
  }

  func testShareIsDisabledWithoutLoadedBytes() async {
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 15), parentID: .root, title: "Doc.pdf", kind: .pdf)
    let failed = PutioPreviewModel(route: .preview(route)) { _, _ in
      throw PutioRuntimeError.transient
    }
    await failed.load()
    XCTAssertEqual(failed.state, .failed(.loadFailed))
    XCTAssertNil(failed.share)

    let unreadable = PutioPreviewModel(route: .preview(route)) { _, _ in Data("%PDF-1.4".utf8) }
    await unreadable.load()
    XCTAssertEqual(unreadable.state, .failed(.cannotShow))
    XCTAssertNil(unreadable.share)

    let archive = PutioViewerRoute.cannotShow(id: PutioFileID(rawValue: 16), title: "a.zip")
    XCTAssertNil(PutioPreviewModel(route: archive) { _, _ in Data() }.share)
  }

  func testSharedImagesNameTheirConcreteType() {
    let cases: [(String, UTType?)] = [
      ("Poster.png", .png), ("Photo.JPG", .jpeg), ("Photo.jpeg", .jpeg), ("Live.heic", .heic),
      ("Loop.gif", .gif), ("Still.webp", .webP), ("Scan.bmp", nil), ("Untitled", nil),
    ]
    for (name, expected) in cases {
      let share = PutioPreviewShareFile(name: name, kind: .image) { URL.temporaryDirectory }
      XCTAssertEqual(share.imageType, expected, name)
    }
    let text = PutioPreviewShareFile(name: "Notes.png", kind: .text) { URL.temporaryDirectory }
    XCTAssertNil(text.imageType)
  }

  func testOverlappingSharesFetchTheWholeTextOnce() async throws {
    let limit = PutioPreviewRoute.textLimitBytes
    let whole = Data(repeating: 0x61, count: limit + 4_000)
    var wholeFetches = 0
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 17), parentID: .root, title: "Long.srt", kind: .text)
    let model = PutioPreviewModel(route: .preview(route)) { _, extent in
      guard extent == .whole else { return whole.prefix(limit + 1) }
      wholeFetches += 1
      for _ in 0..<5 { await Task.yield() }
      return whole
    }
    await model.load()
    let share = try XCTUnwrap(model.share)
    async let first = share.export()
    async let second = share.export()
    let files = try await [first, second]
    XCTAssertEqual(files[0], files[1])
    XCTAssertEqual(wholeFetches, 1)
    model.cancel()
  }

  func testClosingDuringAShareLeavesNoTemporaryDirectory() async throws {
    let limit = PutioPreviewRoute.textLimitBytes
    let gate = PreviewDownloadGate()
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 18), parentID: .root, title: "Long.srt", kind: .text)
    let model = PutioPreviewModel(route: .preview(route)) { _, extent in
      let body = Data(repeating: 0x61, count: limit + 4_000)
      guard extent == .whole else { return body.prefix(limit + 1) }
      await gate.wait()
      return body
    }
    await model.load()
    let share = try XCTUnwrap(model.share)
    let export = Task { try await share.export() }
    while !gate.isWaiting { await Task.yield() }
    model.cancel()
    gate.open()
    do {
      _ = try await export.value
      XCTFail("a closed preview still shared a file")
    } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: model.shareDirectory.path))
  }

  func testRenamingDuringAShareDropsTheExportUnderTheOldName() async throws {
    let limit = PutioPreviewRoute.textLimitBytes
    let gate = PreviewDownloadGate()
    let route = PutioPreviewRoute(
      id: PutioFileID(rawValue: 19), parentID: .root, title: "Old.srt", kind: .text)
    var wholeFetches = 0
    let model = PutioPreviewModel(route: .preview(route)) { _, extent in
      let body = Data(repeating: 0x61, count: limit + 4_000)
      guard extent == .whole else { return body.prefix(limit + 1) }
      wholeFetches += 1
      if wholeFetches == 1 { await gate.wait() }
      return body
    }
    await model.load()
    let stale = Task { try await XCTUnwrap(model.share).export() }
    while !gate.isWaiting { await Task.yield() }
    model.retitle("New.srt")
    gate.open()
    do {
      _ = try await stale.value
      XCTFail("a renamed preview still shared the old name")
    } catch {}
    let share = try XCTUnwrap(model.share)
    XCTAssertEqual(share.name, "New.srt")
    let file = try await share.export()
    XCTAssertEqual(file.lastPathComponent, "New.srt")
    model.cancel()
  }

  func testAFileWhoseActionSettledOffersNoMenuUntilItsLookupReturns() throws {
    let shown = BrowserTestFixtures.item(id: 21, parentID: 5, name: "Poster.png", kind: .image)
    let file = PutioFileRoute(item: shown)
    let viewer = try XCTUnwrap(PutioViewerRoute(opening: file.openAction))
    var listed = [shown]
    let source = PutioPreviewSource(
      items: { listed }, hasMore: { false }, loadMore: { false })
    let pager = PutioPreviewPager(
      opened: viewer, file: file, source: source, download: { _, _ in Data() })
    XCTAssertEqual(pager.item(for: shown.id), shown)

    listed = []
    pager.settle(shown.id)
    XCTAssertNil(pager.item(for: shown.id), "a moved file offered its old folder")

    let moved = BrowserTestFixtures.item(id: 21, parentID: 9, name: "Poster.png", kind: .image)
    pager.update(moved)
    XCTAssertEqual(pager.item(for: shown.id), moved)
  }

  func testRemovingTheShownFileShowsTheNextUntilNoneRemain() throws {
    let images = (1...3).map {
      BrowserTestFixtures.item(id: $0, parentID: 5, name: "\($0).png", kind: .image)
    }
    let file = PutioFileRoute(item: images[1])
    let viewer = try XCTUnwrap(PutioViewerRoute(opening: file.openAction))
    let source = PutioPreviewSource(items: { images }, hasMore: { false }, loadMore: { false })
    let pager = PutioPreviewPager(
      opened: viewer, file: file, source: source, download: { _, _ in Data() })

    XCTAssertTrue(pager.remove(images[1].id))
    XCTAssertEqual(pager.current.id, images[2].id)
    XCTAssertEqual(pager.position?.text, "2 / 2")

    XCTAssertTrue(pager.remove(images[2].id))
    XCTAssertEqual(pager.current.id, images[0].id, "the last file did not fall back")
    XCTAssertNil(pager.position)

    pager.reinstate(images[1].id)
    XCTAssertEqual(pager.current.id, images[1].id, "Undo did not return to the file")
    XCTAssertEqual(pager.position?.text, "2 / 2")

    XCTAssertTrue(pager.remove(images[0].id))
    XCTAssertFalse(pager.remove(images[1].id), "the only file left the viewer open")
  }

  func testRemovingAFileARefreshDroppedStillShowsTheNext() throws {
    let images = (1...3).map {
      BrowserTestFixtures.item(id: $0, parentID: 5, name: "\($0).png", kind: .image)
    }
    var listed = images
    let file = PutioFileRoute(item: images[0])
    let viewer = try XCTUnwrap(PutioViewerRoute(opening: file.openAction))
    let source = PutioPreviewSource(items: { listed }, hasMore: { true }, loadMore: { false })
    let pager = PutioPreviewPager(
      opened: viewer, file: file, source: source, download: { _, _ in Data() })

    XCTAssertTrue(pager.remove(images[0].id))
    XCTAssertEqual(pager.current.id, images[1].id)

    listed = []
    XCTAssertEqual(pager.item(for: images[1].id), images[1], "the next file lost its More rows")
    XCTAssertEqual(pager.position?.text, "1 / 2+", "the next file lost its position")
    XCTAssertTrue(pager.remove(images[1].id), "an unlisted file closed the viewer")
    XCTAssertEqual(pager.current.id, images[2].id)

    pager.settle(images[2].id)
    XCTAssertNil(pager.item(for: images[2].id), "a settling file offered its old snapshot")
  }

  func testAShownFileMissingFromTheRefreshedListingPagesUntilItReturns() async throws {
    let images = (1...10).map {
      BrowserTestFixtures.item(id: $0, parentID: 5, name: "\($0).png", kind: .image)
    }
    var listed = images
    var pages = 0
    let file = PutioFileRoute(item: images[1])
    let viewer = try XCTUnwrap(PutioViewerRoute(opening: file.openAction))
    let source = PutioPreviewSource(
      items: { listed }, hasMore: { true },
      loadMore: {
        pages += 1
        return false
      })
    let pager = PutioPreviewPager(
      opened: viewer, file: file, source: source, download: { _, _ in Data() })
    XCTAssertTrue(pager.remove(images[1].id))
    listed = [images[0]]

    pager.readPagesIfNeeded()
    for _ in 0..<20 { await Task.yield() }
    pager.cancel()
    XCTAssertGreaterThan(pages, 0, "the viewer waited on its snapshot instead of paging")
  }

  func testRemovingTheLastFileAfterPagingStoppedStillRecoversTheRefreshedListing() async throws {
    let images = (1...5).map {
      BrowserTestFixtures.item(id: $0, parentID: 5, name: "\($0).png", kind: .image)
    }
    var listed = images
    var pages = 0
    let file = PutioFileRoute(item: images[4])
    let viewer = try XCTUnwrap(PutioViewerRoute(opening: file.openAction))
    let source = PutioPreviewSource(
      items: { listed }, hasMore: { true },
      loadMore: {
        pages += 1
        return true
      })
    let pager = PutioPreviewPager(
      opened: viewer, file: file, source: source, download: { _, _ in Data() })
    pager.readPagesIfNeeded()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertTrue(pager.reads.stopped, "pages without images did not stop reading")
    let stoppedAt = pages

    XCTAssertTrue(pager.remove(images[4].id))
    XCTAssertEqual(pager.current.id, images[3].id)
    listed = [images[0]]
    pager.readPagesIfNeeded()
    for _ in 0..<20 { await Task.yield() }
    pager.cancel()
    XCTAssertGreaterThan(pages, stoppedAt, "the refreshed listing never paged back to the file")
  }

  func testAFileMovedOutOfItsFolderStopsPagingThatFolder() async throws {
    let shown = BrowserTestFixtures.item(id: 21, parentID: 5, name: "Poster.png", kind: .image)
    let file = PutioFileRoute(item: shown)
    let viewer = try XCTUnwrap(PutioViewerRoute(opening: file.openAction))
    var pages = 0
    let source = PutioPreviewSource(
      items: { [] }, hasMore: { true },
      loadMore: {
        pages += 1
        return true
      })
    let pager = PutioPreviewPager(
      opened: viewer, file: file, source: source, download: { _, _ in Data() })
    pager.update(BrowserTestFixtures.item(id: 21, parentID: 9, name: "Poster.png", kind: .image))

    pager.readPagesIfNeeded()
    for _ in 0..<20 { await Task.yield() }
    pager.cancel()
    XCTAssertEqual(pages, 0, "the viewer paged a folder its file left")
  }

  func testTheTitleSpanCapsTheTitleAtTheNarrowerSideLessTheGap() {
    var span = PutioPreviewTitleSpan()
    span.leading = 60
    span.centre = 30
    XCTAssertNil(span.width)
    span.trailing = 300
    span.centre = 201
    XCTAssertEqual(span.width, 166)
    span.centre = 500
    XCTAssertEqual(span.width, 166)
    span.trailing = 900
    XCTAssertEqual(span.width, 768)
    span.leading = 490
    XCTAssertEqual(span.width, 0)
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
    let model = PutioPreviewModel(route: .preview(route)) { _, _ in
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
    let model = PutioPreviewModel(route: .preview(route)) { _, _ in
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
    let model = PutioPreviewModel(route: .preview(route)) { _, _ in
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

  func testUnfoldingTheDuoRefitsAZoomedDocumentToTheReadableWidth() throws {
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    let data = renderer.pdfData { context in
      context.beginPage()
      context.beginPage()
    }
    let document = try XCTUnwrap(PDFDocument(data: data))
    let view = PutioInsetPDFView(frame: CGRect(origin: .zero, size: Self.duoFolded))
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.document = document
    view.layoutIfNeeded()
    view.scaleFactor = view.scaleFactorForSizeToFit * 3

    view.frame = CGRect(origin: .zero, size: Self.duoOpen)
    view.traitOverrides.horizontalSizeClass = .regular
    view.updateTraitsIfNeeded()
    view.layoutIfNeeded()
    XCTAssertEqual(view.scaleFactor, PutioInsetPDFView.maximumPageWidth / 612, accuracy: 0.01)
    XCTAssertLessThan(view.scaleFactor, view.scaleFactorForSizeToFit)
    XCTAssertTrue(view.document === document)

    view.frame = CGRect(origin: .zero, size: Self.duoFolded)
    view.traitOverrides.horizontalSizeClass = .compact
    view.updateTraitsIfNeeded()
    view.layoutIfNeeded()
    XCTAssertEqual(view.scaleFactor, view.scaleFactorForSizeToFit, accuracy: 0.01)
  }

  func testCompactWidthFitsPDFPagesEdgeToEdge() throws {
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    let document = try XCTUnwrap(PDFDocument(data: renderer.pdfData { $0.beginPage() }))
    let view = PutioInsetPDFView(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
    view.traitOverrides.horizontalSizeClass = .compact
    view.updateTraitsIfNeeded()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.document = document
    view.layoutIfNeeded()
    XCTAssertEqual(view.scaleFactor, view.scaleFactorForSizeToFit, accuracy: 0.01)
    XCTAssertGreaterThan(view.scaleFactor, PutioInsetPDFView.maximumPageWidth / 612)
  }

  func testTheWidestPageSetsTheReadableWidthCap() throws {
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    let data = renderer.pdfData { context in
      context.beginPage()
      context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 792, height: 612), pageInfo: [:])
    }
    let document = try XCTUnwrap(PDFDocument(data: data))
    let view = PutioInsetPDFView(frame: CGRect(origin: .zero, size: Self.duoOpen))
    view.traitOverrides.horizontalSizeClass = .regular
    view.updateTraitsIfNeeded()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.document = document
    view.layoutIfNeeded()
    XCTAssertEqual(view.scaleFactor, PutioInsetPDFView.maximumPageWidth / 792, accuracy: 0.01)
    XCTAssertEqual(view.zoomBaseline, view.scaleFactor, accuracy: 0.001)
  }

  private static let duoFolded = CGSize(width: 466, height: 678)
  private static let duoOpen = CGSize(width: 951, height: 669)

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

@MainActor
private final class PreviewDownloadGate {
  private var continuation: CheckedContinuation<Void, Never>?

  var isWaiting: Bool { continuation != nil }

  func wait() async {
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    continuation?.resume()
    continuation = nil
  }
}
