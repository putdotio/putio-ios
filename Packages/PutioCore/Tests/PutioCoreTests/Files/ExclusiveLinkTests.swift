import Foundation
import XCTest

@testable import PutioCore

@MainActor
final class ExclusiveLinkTests: XCTestCase {
  private let link = URL(string: "https://app.put.io/exclusive-access/8f3KxQ2mVt7")!

  func testCreatingShowsTheLinkAndCannotCreateAgain() async {
    let server = LinkServer([.success(link)])
    let model = PutioExclusiveLinkModel(item: item, create: server.create)
    XCTAssertTrue(model.canCreate)
    await model.create()
    XCTAssertEqual(model.state, .created(link))
    XCTAssertFalse(model.canCreate)
    await model.create()
    XCTAssertEqual(server.calls, [item.id])
  }

  func testRefusalsKeepTheirReasonAndAllowAnotherTry() async {
    let server = LinkServer([.failure(PutioPublicLinkRefusal.daily), .success(link)])
    let model = PutioExclusiveLinkModel(item: item, create: server.create)
    await model.create()
    XCTAssertEqual(model.state, .refused(.daily))
    XCTAssertTrue(model.canCreate)
    await model.create()
    XCTAssertEqual(model.state, .created(link))
  }

  func testOtherFailuresNameTheirReasonAndRetry() async {
    let server = LinkServer([.failure(PutioRuntimeError.transient), .success(link)])
    let model = PutioExclusiveLinkModel(item: item, create: server.create)
    await model.create()
    XCTAssertEqual(
      model.state, .failed("Couldn’t create a link. Check your connection and try again."))
    await model.create()
    XCTAssertEqual(model.state, .created(link))
  }

  func testCancellingOrLosingTheSessionShowsNoFailure() async {
    for error: Error in [CancellationError(), PutioRuntimeError.sessionExpired] {
      let model = PutioExclusiveLinkModel(item: item, create: LinkServer([.failure(error)]).create)
      await model.create()
      XCTAssertEqual(model.state, .ready, "\(error)")
    }
  }

  func testClosingTheSheetMidRequestDropsTheLink() async {
    let started = expectation(description: "request started")
    let model = PutioExclusiveLinkModel(item: item) { [link] _ in
      started.fulfill()
      try await Task.sleep(for: .seconds(30))
      return link
    }
    let task = Task { await model.create() }
    await fulfillment(of: [started], timeout: 5)
    XCTAssertEqual(model.state, .creating)
    task.cancel()
    await task.value
    XCTAssertEqual(model.state, .ready)
  }

  func testRefusalsReadPutioErrorTypes() {
    let mapped: [String: PutioPublicLinkRefusal] = [
      "PUBLIC_SHARE_NOT_ALLOWED_PLAN": .plan,
      "PUBLIC_SHARE_UNSUPPORTED_FILE_TYPE": .fileType,
      "PUBLIC_SHARE_EXCEEDED_LIMIT": .linkLimit,
      "PUBLIC_SHARE_SINGLE_FILE_LIMIT_EXCEEDED": .linkLimit,
      "PUBLIC_SHARE_FOLDER_LINK_COUNT_LIMIT_EXCEEDED": .linkLimit,
      "PUBLIC_SHARE_FOLDER_MAX_SIZE_LIMIT_EXCEEDED": .folderSize,
      "PUBLIC_SHARE_FOLDER_MAX_CHILDREN_LIMIT_EXCEEDED": .folderChildren,
      "PUBLIC_SHARE_DAILY_TOTAL_LINK_COUNT_EXCEEDED": .daily,
      "PUBLIC_SHARE_WEEKLY_TOTAL_LINK_COUNT_EXCEEDED": .weekly,
    ]
    for (type, refusal) in mapped {
      XCTAssertEqual(PutioPublicLinkRefusal(apiErrorType: type), refusal, type)
    }
    XCTAssertNil(PutioPublicLinkRefusal(apiErrorType: "PUBLIC_SHARE_FOLDER_ROOT_NOT_ALLOWED"))
    XCTAssertEqual(
      Set(PutioPublicLinkRefusal.allCases.map(\.message)).count,
      PutioPublicLinkRefusal.allCases.count)
  }

  func testSheetCopyCutsLongNamesInTheMiddleAndDropsTheScheme() {
    XCTAssertEqual(
      PutioExclusiveLinkCopy.displayName("Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv"),
      "Blue.Lights.S04E02…ORGANiC.mkv")
    XCTAssertEqual(PutioExclusiveLinkCopy.displayName("IMG_4392.HEIC"), "IMG_4392.HEIC")
    XCTAssertEqual(PutioExclusiveLinkCopy.address(link), "app.put.io/exclusive-access/8f3KxQ2mVt7")
    XCTAssertEqual(
      PutioExclusiveLinkCopy.body(name: "Blue Lights"),
      "Anyone with a link can open Blue Lights. A link stops working after 72 hours, or sooner when it hits its IP or data limit."
    )
  }

  private let item = PutioFileItem(
    id: PutioFileID(rawValue: 442), parentID: PutioFileID(rawValue: 440),
    name: "Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv", kind: .video, sizeBytes: 1,
    createdAt: .distantPast, updatedAt: .distantPast, resumePositionSeconds: 0, isShared: false)
}

@MainActor
private final class LinkServer {
  private var outcomes: [Result<URL, Error>]
  private(set) var calls: [PutioFileID] = []

  init(_ outcomes: [Result<URL, Error>]) {
    self.outcomes = outcomes
  }

  var create: PutioPublicLinkCreate {
    { [self] fileID in
      calls.append(fileID)
      return try outcomes.removeFirst().get()
    }
  }
}
