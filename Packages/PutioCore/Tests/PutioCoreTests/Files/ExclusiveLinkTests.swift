import Foundation
import XCTest

@testable import PutioCore

@MainActor
final class ExclusiveLinkTests: XCTestCase {
  private let link = URL(string: "https://app.put.io/exclusive-access/8f3KxQ2mVt7")!

  func testCreatingShowsTheLinkAndCannotCreateAgain() async {
    let server = LinkServer([.success(link)])
    let model = await opened(create: server.create)
    XCTAssertTrue(model.canCreate)
    await create(model)
    XCTAssertEqual(model.state, .created(link))
    XCTAssertFalse(model.canCreate)
    XCTAssertFalse(model.start(), "a second tap started another request")
    await create(model)
    XCTAssertEqual(server.calls, [item.id])
  }

  func testRefusalsKeepTheirReasonAndAllowAnotherTry() async {
    let server = LinkServer([.failure(PutioPublicLinkRefusal.daily), .success(link)])
    let model = await opened(create: server.create)
    await create(model)
    XCTAssertEqual(model.state, .refused(.daily))
    XCTAssertTrue(model.canCreate)
    await create(model)
    XCTAssertEqual(model.state, .created(link))
  }

  func testOtherFailuresNameTheirReasonAndRetry() async {
    let server = LinkServer([.failure(PutioRuntimeError.transient), .success(link)])
    let model = await opened(create: server.create)
    await create(model)
    XCTAssertEqual(
      model.state, .failed("Couldn’t create a link. Check your connection and try again."))
    await create(model)
    XCTAssertEqual(model.state, .created(link))
  }

  func testCancellingOrLosingTheSessionShowsNoFailure() async {
    for error: Error in [CancellationError(), PutioRuntimeError.sessionExpired] {
      let model = await opened(create: LinkServer([.failure(error)]).create)
      await create(model)
      XCTAssertEqual(model.state, .ready, "\(error)")
    }
  }

  func testCancellingMidRequestDropsTheLink() async {
    let started = expectation(description: "request started")
    let model = await opened { [link] _ in
      started.fulfill()
      try await Task.sleep(for: .seconds(30))
      return link
    }
    let task = Task { await create(model) }
    await fulfillment(of: [started], timeout: 5)
    XCTAssertEqual(model.state, .creating)
    task.cancel()
    await task.value
    XCTAssertEqual(model.state, .ready)
  }

  func testCancellingAfterTheServerCreatedTheLinkStillShowsIt() async {
    let model = await opened { [link] _ in
      withUnsafeCurrentTask { $0?.cancel() }
      return link
    }
    await Task { await create(model) }.value
    XCTAssertEqual(model.state, .created(link))
  }

  func testReopeningTheSheetFindsARequestInFlightOrTheLinkItCreated() async {
    let links = PutioExclusiveLinks()
    let started = expectation(description: "request started")
    let answer = AsyncStream<Void>.makeStream()
    let server: PutioPublicLinkCreate = { [link] _ in
      started.fulfill()
      for await _ in answer.stream { break }
      return link
    }
    let first = links.model(for: item, actions: actions(create: server))
    await first.findExisting()
    XCTAssertTrue(
      links.model(for: item, actions: actions(create: server)) === first,
      "redrawing the sheet lost it")
    let task = Task { await create(first) }
    await fulfillment(of: [started], timeout: 5)
    links.sheetClosed()
    let reopening = links.model(for: item, actions: actions(create: server))
    XCTAssertTrue(reopening === first, "reopening lost the request")
    await reopening.findExisting()
    XCTAssertEqual(reopening.state, .creating, "reopening looked up over the request")
    answer.continuation.yield()
    await task.value
    links.sheetClosed()
    let reopened = links.model(for: item, actions: actions(create: server))
    XCTAssertTrue(reopened === first, "reopening lost the link")
    XCTAssertEqual(reopened.state, .created(link))
  }

  func testReopeningAfterAFailureOrRefusalStartsAgain() async {
    for outcome: Error in [PutioPublicLinkRefusal.daily, PutioRuntimeError.transient] {
      let links = PutioExclusiveLinks()
      let server = actions(create: LinkServer([.failure(outcome)]).create)
      let first = links.model(for: item, actions: server)
      await first.findExisting()
      await create(first)
      XCTAssertTrue(links.model(for: item, actions: server) === first, "\(outcome)")
      links.sheetClosed()
      let reopened = links.model(for: item, actions: server)
      XCTAssertTrue(reopened !== first, "\(outcome)")
      await reopened.findExisting()
      XCTAssertEqual(reopened.state, .ready, "\(outcome)")
    }
  }

  func testOpeningShowsTheItemsLiveLinkInsteadOfCreatingAnother() async {
    let server = LinkServer([.success(link)])
    var asked: [PutioFileID] = []
    let model = PutioExclusiveLinkModel(
      item: item,
      actions: actions(
        find: { [link] in
          asked.append($0)
          return link
        }, create: server.create))
    XCTAssertEqual(model.state, .finding)
    XCTAssertFalse(model.start(), "Create ran before the lookup answered")
    await model.findExisting()
    XCTAssertEqual(asked, [item.id])
    XCTAssertEqual(model.state, .created(link))
    XCTAssertFalse(model.start(), "Create offered a second link")
    XCTAssertEqual(server.calls, [])
  }

  func testOpeningWithNoLiveLinkOrAFailedLookupOffersCreate() async {
    let finds: [PutioPublicLinkFind] = [
      { _ in nil }, { _ in throw PutioRuntimeError.transient }, { _ in throw CancellationError() },
    ]
    for find in finds {
      let model = await opened(find: find, create: LinkServer([.success(link)]).create)
      XCTAssertEqual(model.state, .ready)
      await create(model)
      XCTAssertEqual(model.state, .created(link))
    }
  }

  func testReopeningAfterTheLinkWasRevokedOrExpiredOffersCreate() async {
    let links = PutioExclusiveLinks()
    let server = actions(find: { _ in nil }, create: LinkServer([.success(link)]).create)
    let first = links.model(for: item, actions: server)
    await first.findExisting()
    await create(first)
    XCTAssertEqual(first.state, .created(link))
    links.sheetClosed()
    let reopened = links.model(for: item, actions: server)
    await reopened.findExisting()
    XCTAssertEqual(reopened.state, .ready, "the sheet kept a link the server no longer has")
  }

  func testAFailedLookupKeepsTheLinkTheSheetAlreadyShows() async {
    let links = PutioExclusiveLinks()
    var lookupFails = false
    let server = actions(
      find: { _ in
        if lookupFails { throw PutioRuntimeError.transient }
        return nil
      }, create: LinkServer([.success(link)]).create)
    let first = links.model(for: item, actions: server)
    await first.findExisting()
    await create(first)
    links.sheetClosed()
    lookupFails = true
    let reopened = links.model(for: item, actions: server)
    await reopened.findExisting()
    XCTAssertEqual(reopened.state, .created(link))
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

  private func create(_ model: PutioExclusiveLinkModel) async {
    if model.start() { await model.create() }
  }

  private func actions(
    find: @escaping PutioPublicLinkFind = { _ in nil },
    create: @escaping PutioPublicLinkCreate
  ) -> PutioExclusiveLinkActions {
    PutioExclusiveLinkActions(find: find, create: create)
  }

  private func opened(
    find: @escaping PutioPublicLinkFind = { _ in nil },
    create: @escaping PutioPublicLinkCreate
  ) async -> PutioExclusiveLinkModel {
    let model = PutioExclusiveLinkModel(item: item, actions: actions(find: find, create: create))
    await model.findExisting()
    return model
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
