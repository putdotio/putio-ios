import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import Putio
@testable import PutioCore

@MainActor
final class PlaybackPreferencesViewTests: XCTestCase {
  func testAutoplaySwitchIsHiddenWhileSuggestionsAreOff() async throws {
    let model = model(load: { PutioAppConfig(autoplayNextVideo: true) })
    await model.loadIfNeeded()

    let suggested = host(
      PutioNextVideoPreferencesSection(suggestsNextVideo: true, appConfig: model))
    defer { suggested.isHidden = true }
    let shown = try await switchCount(in: suggested)
    XCTAssertEqual(shown, 1, "the autoplay switch is missing while suggestions are on")

    let unsuggested = host(
      PutioNextVideoPreferencesSection(suggestsNextVideo: false, appConfig: model))
    defer { unsuggested.isHidden = true }
    let hidden = try await switchCount(in: unsuggested)
    XCTAssertEqual(hidden, 0, "autoplay is offered for suggestions the account turned off")
  }

  private func host(_ section: PutioNextVideoPreferencesSection) -> UIWindow {
    let controller = UIHostingController(rootView: Form { section })
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = controller
    window.isHidden = false
    controller.view.frame = window.bounds
    window.layoutIfNeeded()
    return window
  }

  /// Lets the form lay out its rows before counting.
  private func switchCount(in window: UIWindow) async throws -> Int {
    for _ in 0..<20 {
      try await Task.sleep(for: .milliseconds(10))
      window.layoutIfNeeded()
    }
    return countSwitches(in: window)
  }

  private func countSwitches(in view: UIView) -> Int {
    (view is UISwitch ? 1 : 0) + view.subviews.reduce(0) { $0 + countSwitches(in: $1) }
  }

  private func model(
    load: @escaping @MainActor @Sendable () async throws -> PutioAppConfig,
    save: @escaping @MainActor @Sendable (Bool) async throws -> Void = { _ in }
  ) -> PutioAppConfigModel {
    PutioAppConfigModel(actions: .init(load: load, saveAutoplayNextVideo: save))
  }
}
