import Foundation
import PutioCore

#if DEBUG && (os(iOS) || os(tvOS))
  @MainActor
  enum HarnessContinueWatching {
    static let argument = "--putio-harness-continue-watching"
    private static var seeded = false
    #if os(tvOS)
      private static let seededScenario = HarnessScenario.signedIn
    #else
      private static let seededScenario = HarnessScenario.filesBrowser
    #endif

    static func seed(scenario: HarnessScenario, accountID: Int) {
      guard scenario == seededScenario, !seeded else { return }
      seeded = true
      let arguments = ProcessInfo.processInfo.arguments
      let mode = arguments.firstIndex(of: argument).flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
      }
      let store = PutioContinueWatchingStore(accountID: accountID)
      switch mode {
      case "keep":
        return
      case "three":
        store.write(threeVideos)
      case "home":
        store.write(homeVideos)
      default:
        PutioContinueWatchingStore.clear(accountID: accountID)
      }
    }

    /// Home's cards: an hour-long clock at the 2% floor, then two minute clocks.
    private static var homeVideos: [PutioContinueWatchingEntry] {
      let now = Date.now
      return [
        PutioContinueWatchingEntry(
          fileID: PutioFileID(rawValue: 411), parentID: PutioFileID(rawValue: 410),
          name: "Nested Movie.mkv", positionSeconds: 90, durationSeconds: 5_000, watchedAt: now),
        PutioContinueWatchingEntry(
          fileID: PutioFileID(rawValue: 412), parentID: .root, name: "Root Movie.mkv",
          positionSeconds: 560, durationSeconds: 903, watchedAt: now.addingTimeInterval(-60)),
        PutioContinueWatchingEntry(
          fileID: PutioFileID(rawValue: 414), parentID: .root, name: "Root Movie 2.mkv",
          positionSeconds: 37, durationSeconds: 205, watchedAt: now.addingTimeInterval(-120)),
      ]
    }

    private static var threeVideos: [PutioContinueWatchingEntry] {
      let now = Date.now
      return [
        PutioContinueWatchingEntry(
          fileID: PutioFileID(rawValue: 442), parentID: PutioFileID(rawValue: 440),
          name: "Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv", positionSeconds: 1_260,
          durationSeconds: 3_127, watchedAt: now),
        PutioContinueWatchingEntry(
          fileID: PutioFileID(rawValue: 411), parentID: PutioFileID(rawValue: 410),
          name: "Nested Movie.mkv", positionSeconds: 90, durationSeconds: 872,
          watchedAt: now.addingTimeInterval(-60)),
        PutioContinueWatchingEntry(
          fileID: PutioFileID(rawValue: 414), parentID: .root, name: "Root Movie 2.mkv",
          positionSeconds: 37, durationSeconds: 1_500, watchedAt: now.addingTimeInterval(-120)),
      ]
    }
  }
#endif
