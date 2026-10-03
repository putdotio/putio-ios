import PutioCore
import SwiftUI
import XCTest

@testable import Putio

final class WelcomeScreenRenderingTests: XCTestCase {
  @MainActor
  func testWelcomeStatesMatchBaselines() throws {
    let states: [(String, WelcomeScreen.Mode)] = [
      ("welcome-fresh", .fresh),
      ("welcome-session-expired", .sessionExpired),
      (
        "welcome-sign-in-failed",
        .signInFailed("Sign-in didn't finish. Nothing was saved, so you can try again.")
      ),
    ]
    for (name, mode) in states {
      _ = try assertRenderingSnapshot(name: name, view: phone(mode), size: Self.viewport)
    }
    _ = try assertRenderingSnapshot(
      name: "welcome-restore-failed-accessibility3",
      view: phone(.restoreFailed("put.io is unreachable. Check your connection and try again.")),
      size: Self.viewport,
      dynamicTypeSize: .accessibility3
    )
  }

  // The mock's phone: 393x852 with a 59pt status bar and 34pt home indicator.
  private static let viewport = CGSize(width: 393, height: 852)

  @MainActor
  private func phone(_ mode: WelcomeScreen.Mode) -> some View {
    WelcomeScreen(mode: mode)
      .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 59) }
      .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 34) }
      .background(PutioTheme.Colors.background)
      // The host window's own insets would stack on the simulated ones.
      .ignoresSafeArea()
      .tint(PutioTheme.Colors.accent)
  }
}
