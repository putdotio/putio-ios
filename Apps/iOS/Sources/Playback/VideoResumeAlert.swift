import AVFoundation
import PutioCore
import SwiftUI

extension View {
  func putioVideoResumeAlert(_ prompter: PutioVideoResumePrompter) -> some View {
    let time = PutioFileDetailText.clock(seconds: prompter.positionSeconds)
    return putioAlert(
      String(localized: "Resume from \(time)?"),
      isPresented: Binding(get: { prompter.isAsking }, set: { if !$0 { prompter.close() } }),
      actions: [
        PutioAlertAction(
          String(localized: "Start over"), tier: .neutral, id: "video.resume.start-over"
        ) { prompter.answer(.startOver) },
        PutioAlertAction(String(localized: "Resume"), tier: .primary, id: "video.resume.resume") {
          prompter.answer(.resume)
        },
      ])
  }
}

enum PutioVideoLength {
  static func seconds(of url: URL) async -> Double? {
    guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric
    else { return nil }
    return CMTimeGetSeconds(duration)
  }
}
