import PutioCore
import UserNotifications
import XCTest

@testable import Putio

@MainActor
final class OfflineNotificationsTests: XCTestCase {
  func testTheRowFollowsTheAuthorizationStatus() async {
    var answers: [UNAuthorizationStatus] = [.denied, .authorized, .notDetermined, .denied]
    let status = PutioOfflineNotificationStatus(readStatus: { answers.removeFirst() })
    XCTAssertFalse(status.showsRow(hasDownloads: true), "the row showed before any check")

    await status.refresh()
    XCTAssertTrue(status.showsRow(hasDownloads: true), "denied permission showed no row")
    XCTAssertFalse(status.showsRow(hasDownloads: false), "the row showed on an empty tab")

    await status.refresh()
    XCTAssertFalse(status.showsRow(hasDownloads: true), "the row stayed after permission")

    await status.refresh()
    XCTAssertFalse(status.showsRow(hasDownloads: true), "an unanswered prompt showed the row")

    await status.refresh()
    XCTAssertTrue(status.showsRow(hasDownloads: true), "the row did not return when denied")
  }

  func testAFailedDownloadPostsTheFileNameAndTheShortReason() {
    let failure = PutioOfflineFailure(
      kind: .resolution, message: "Check your connection and try again.")
    let item = PutioOfflineItem(
      id: PutioFileID(rawValue: 9), parentID: .root, name: "Episode 1.mkv", kind: .video,
      createdAt: .now, stage: .failed(failure), localPath: nil, storedBytes: 0,
      selectedAudioLanguages: [], storedAudioTracks: [], storedSubtitleTracks: [],
      resumePositionSeconds: 0, pendingPositionSeconds: nil, estimatedBytes: 4_000)

    let content = PutioOfflineNotifications.failureContent(item, failure)

    XCTAssertEqual(content.title, "Download failed")
    XCTAssertEqual(content.subtitle, "Episode 1.mkv")
    XCTAssertEqual(content.body, "Connection lost")
  }
}
