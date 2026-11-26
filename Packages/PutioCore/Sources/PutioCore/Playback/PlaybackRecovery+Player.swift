import Foundation

#if os(iOS) || os(tvOS) || os(macOS)
  extension PutioVideoPlaybackModel {
    /// Reports a player failure and recovers from it: the converted copy
    /// when the original never showed a frame, a silent access refresh
    /// that resumes at the held position, or the failed state. The report
    /// for a refresh that also fails arrives when the refresh ends.
    /// `fellBack` says whether the converted copy takes over.
    @discardableResult
    public func handlePlayerFailure(
      _ failure: PutioVideoPlayerFailure, platform: PutioPlaybackFailureReport.Platform,
      report: @escaping @MainActor (PutioPlaybackFailureReport) -> Void
    ) -> (fellBack: Bool, recovery: Task<Void, Never>) {
      let fellBack = fallsBack(after: failure.fault, beforeFirstFrame: failure.beforeFirstFrame)
      if let immediate = failureReport(
        failure.error, beforeFirstFrame: failure.beforeFirstFrame, platform: platform)
      {
        report(immediate)
      }
      let recovery = Task {
        let refreshFailure = await playerFailed(
          failure.fault, heldSeconds: failure.heldSeconds,
          beforeFirstFrame: failure.beforeFirstFrame)
        if let refreshFailure { report(refreshFailure) }
      }
      return (fellBack, recovery)
    }
  }
#endif
