import Foundation
import XCTest

@testable import PutioCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
final class PublicLinksTests: XCTestCase {
  private func link(_ id: Int, hours: Double?) -> PutioPublicLink {
    PutioPublicLink(
      id: id, fileName: "File \(id).mkv", kind: .video,
      expiresAt: hours.map { now.addingTimeInterval($0 * 3600) },
      url: URL(string: "https://app.put.io/exclusive-access/t\(id)")!)
  }

  func testExpiredLinksAreHiddenAndAFailedLoadRetries() async {
    var loads = 0
    let links = [link(1, hours: 71.9), link(2, hours: nil), link(3, hours: -0.1)]
    let model = PutioPublicLinksModel(
      actions: PutioPublicLinkActions(
        list: {
          loads += 1
          if loads == 1 { throw PutioRuntimeError.transient }
          return links
        },
        now: { now }))
    await model.loadOnOpen()
    XCTAssertEqual(model.state, .failed)
    await model.loadOnOpen()
    XCTAssertEqual(loads, 1, "reappearing reloaded the list")
    await model.load()
    XCTAssertEqual(model.links.map(\.id), [1, 2])
  }

  func testACancelledLoadLeavesTheScreenAsItWas() async {
    let model = PutioPublicLinksModel(
      actions: PutioPublicLinkActions(list: { throw CancellationError() }))
    await model.load()
    XCTAssertEqual(model.state, .loading)
  }

  func testAFailedRevokeKeepsTheRowAndTheLastRevokeEmptiesTheList() async {
    var revoked: [Int] = []
    let model = PutioPublicLinksModel(
      actions: PutioPublicLinkActions(
        list: {
          [
            PutioPublicLink(
              id: 1, fileName: "A", kind: .video, expiresAt: now.addingTimeInterval(3600),
              url: URL(string: "https://app.put.io/exclusive-access/a")!),
            PutioPublicLink(
              id: 2, fileName: "B", kind: .image, expiresAt: nil,
              url: URL(string: "https://app.put.io/exclusive-access/b")!),
          ]
        },
        revoke: { id in
          revoked.append(id)
          if revoked.count == 1 { throw PutioRuntimeError.transient }
          if id == 2 { throw PutioRuntimeError.notFound }
        },
        now: { now }))
    await model.load()
    let first = model.links[0]
    let outcome = await model.revoke(first)
    XCTAssertEqual(
      outcome, .failed("Couldn’t revoke the link. Check your connection and try again."))
    XCTAssertEqual(model.links.map(\.id), [1, 2])
    let retried = await model.revoke(first)
    XCTAssertEqual(retried, .revoked)
    XCTAssertEqual(model.links.map(\.id), [2])
    let repeated = await model.revoke(first)
    XCTAssertEqual(repeated, .skipped)
    let gone = await model.revoke(model.links[0])
    XCTAssertEqual(gone, .revoked, "a gone link stayed listed")
    XCTAssertEqual(model.state, .loaded([]))
    XCTAssertEqual(revoked, [1, 1, 2])
  }

  func testAFailedRefreshKeepsTheRowsAndARevokeSurvivesARefreshInFlight() async {
    var loads = 0
    var release: CheckedContinuation<Void, Never>?
    let model = PutioPublicLinksModel(
      actions: PutioPublicLinkActions(
        list: {
          loads += 1
          if loads == 2 { throw PutioRuntimeError.transient }
          if loads == 3 { await withCheckedContinuation { release = $0 } }
          return [link(1, hours: 10), link(2, hours: 20), link(3, hours: 30)]
        },
        now: { now }))
    await model.load()
    let refreshed = await model.load()
    XCTAssertFalse(refreshed, "a failed refresh reported success")
    XCTAssertEqual(model.links.map(\.id), [1, 2, 3], "a failed refresh dropped the rows")
    let refresh = Task { await model.load() }
    while release == nil { await Task.yield() }
    let outcome = await model.revoke(model.links[0])
    XCTAssertEqual(outcome, .revoked)
    release?.resume()
    let landed = await refresh.value
    XCTAssertTrue(landed)
    XCTAssertEqual(model.links.map(\.id), [2, 3], "the refresh dropped or undid the revoke")
  }

  func testLinksThatExpireWhileShownLeaveTheList() async {
    let model = PutioPublicLinksModel(
      actions: PutioPublicLinkActions(list: { [link(1, hours: 0.2)] }, now: { now }))
    await model.load()
    XCTAssertEqual(model.links(at: now).map(\.id), [1])
    XCTAssertTrue(model.links(at: now.addingTimeInterval(3600)).isEmpty)
  }

  func testExpiryTextCountsWholeHoursLeft() {
    XCTAssertEqual(link(1, hours: 71.99).expiryText(at: now), "Expires in 71 hours")
    XCTAssertEqual(link(1, hours: 0.4).expiryText(at: now), "Expires in 1 hour")
    XCTAssertEqual(link(1, hours: nil).expiryText(at: now), "Expires within 72 hours")
    XCTAssertTrue(link(1, hours: 0).isExpired(at: now))
    XCTAssertFalse(link(1, hours: nil).isExpired(at: now))
  }
}
