import PutioCore
import SwiftUI
import XCTest

@testable import Putio

final class ProductAnalyticsPromptRenderingTests: XCTestCase {
  @MainActor
  func testPromptMatchesBaselinesAtDefaultAndCappedTextSizes() throws {
    let model = PutioProductAnalyticsPromptModel(
      actions: PutioProductAnalyticsPromptActions(saveSetting: { _ in }, markAnswered: {}))
    // iOS 27's glyph antialiasing drifts past the comparison tolerance on
    // this text-dense sheet at default size.
    var defaultName = "analytics-prompt-default"
    if #available(iOS 27.0, *) { defaultName += "-ios27" }
    _ = try assertRenderingSnapshot(
      name: defaultName,
      view: sheet(model),
      size: CGSize(width: 393, height: 680))
    _ = try assertRenderingSnapshot(
      name: "analytics-prompt-accessibility2",
      view: sheet(model),
      size: CGSize(width: 393, height: 1060),
      dynamicTypeSize: .accessibility2)
  }

  @MainActor
  private func sheet(_ model: PutioProductAnalyticsPromptModel) -> some View {
    ProductAnalyticsPromptView(model: model)
      .tint(PutioTheme.Colors.accent)
  }
}
