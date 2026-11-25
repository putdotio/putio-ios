import PutioCore
import SwiftUI

extension View {
  func putioVideoResumeAlert(_ prompter: PutioVideoResumePrompter) -> some View {
    putioAlert(
      PutioVideoResumePrompt.question(positionSeconds: prompter.positionSeconds),
      isPresented: Binding(get: { prompter.isAsking }, set: { if !$0 { prompter.close() } }),
      actions: [
        PutioAlertAction(
          PutioVideoResumePrompt.startOverTitle, tier: .neutral, id: "video.resume.start-over"
        ) { prompter.answer(.startOver) },
        PutioAlertAction(
          PutioVideoResumePrompt.resumeTitle, tier: .primary, id: "video.resume.resume"
        ) {
          prompter.answer(.resume)
        },
      ])
  }
}
