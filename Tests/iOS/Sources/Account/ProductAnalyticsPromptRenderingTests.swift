import PutioCore
import SwiftUI
import XCTest

@testable import Putio

final class ProductAnalyticsPromptRenderingTests: XCTestCase {
  @MainActor
  func testPromptMatchesBaselinesAtDefaultAndCappedTextSizes() throws {
    let model = PutioProductAnalyticsPromptModel(
      actions: PutioProductAnalyticsPromptActions(saveSetting: { _ in }, markAnswered: {}))
    _ = try assertRenderingSnapshot(
      name: "analytics-prompt-default",
      view: sheet(model),
      size: CGSize(width: 393, height: 680))
    _ = try assertRenderingSnapshot(
      name: "analytics-prompt-xxlarge",
      view: sheet(model),
      size: CGSize(width: 393, height: 860),
      dynamicTypeSize: .xxLarge)
  }

  @MainActor
  private func sheet(_ model: PutioProductAnalyticsPromptModel) -> some View {
    ProductAnalyticsPromptView(model: model)
      .tint(PutioTheme.Colors.accent)
  }
}
