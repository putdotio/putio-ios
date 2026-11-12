import PutioCore
import SwiftUI
import XCTest

@testable import Putio

final class WelcomeScreenRenderingTests: XCTestCase {
  @MainActor
  func testPhoneWelcomeStatesMatchBaselines() throws {
    let states: [(String, WelcomeScreen)] = [
      ("welcome-fresh", WelcomeScreen(mode: .fresh, pinnedFrame: 0)),
      ("welcome-frame-2", WelcomeScreen(mode: .fresh, pinnedFrame: 1)),
      (
        "welcome-checking-session",
        WelcomeScreen(mode: .fresh, isCheckingSession: true, pinnedFrame: 0)
      ),
      ("welcome-sign-in-failed", WelcomeScreen(mode: .signInFailed)),
      ("welcome-session-expired", WelcomeScreen(mode: .sessionExpired, pinnedFrame: 0)),
    ]
    for (name, screen) in states {
      _ = try assertRenderingSnapshot(name: name, view: Self.phone(screen), size: Self.phoneSize)
    }
  }

  @MainActor
  func testPadWelcomeStatesCentreOneColumn() throws {
    let states: [(String, WelcomeScreen)] = [
      ("welcome-fresh-regular", WelcomeScreen(mode: .fresh, deviceNoun: .iPad, pinnedFrame: 0)),
      ("welcome-sign-in-failed-regular", WelcomeScreen(mode: .signInFailed, deviceNoun: .iPad)),
    ]
    for (name, screen) in states {
      _ = try assertRenderingSnapshot(name: name, view: Self.pad(screen), size: Self.padSize)
    }
  }

  @MainActor
  func testLargeTextScrollsTheCopyAndKeepsTheButtonPinned() throws {
    _ = try assertRenderingSnapshot(
      name: "welcome-sign-in-failed-xxlarge-short",
      view: Self.phone(WelcomeScreen(mode: .signInFailed), top: 20, bottom: 0),
      size: Self.shortPhoneSize,
      dynamicTypeSize: .xxLarge
    )
    _ = try assertRenderingSnapshot(
      name: "welcome-restore-failed-accessibility3",
      view: Self.phone(
        WelcomeScreen(
          mode: .restoreFailed("put.io is unreachable. Check your connection and try again."))),
      size: Self.phoneSize,
      dynamicTypeSize: .accessibility3
    )
  }

  private static let phoneSize = CGSize(width: 402, height: 874)
  private static let shortPhoneSize = CGSize(width: 375, height: 667)
  private static let padSize = CGSize(width: 1210, height: 834)

  @MainActor
  private static func phone(
    _ screen: WelcomeScreen, top: CGFloat = 62, bottom: CGFloat = 34
  ) -> some View {
    device(screen, top: top, bottom: bottom, sizeClass: .compact)
  }

  @MainActor
  private static func pad(_ screen: WelcomeScreen) -> some View {
    device(screen, top: 24, bottom: 20, sizeClass: .regular)
  }

  @MainActor
  private static func device(
    _ screen: WelcomeScreen, top: CGFloat, bottom: CGFloat, sizeClass: UserInterfaceSizeClass
  ) -> some View {
    screen
      .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: top) }
      .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: bottom) }
      .background(PutioTheme.Colors.background)
      .ignoresSafeArea()
      .environment(\.horizontalSizeClass, sizeClass)
      .tint(PutioTheme.Colors.accent)
  }
}
