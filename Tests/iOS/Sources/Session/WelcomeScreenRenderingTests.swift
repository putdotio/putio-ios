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
      ("welcome-session-check-failed", WelcomeScreen(mode: .restoreFailed(.sessionCheck))),
      ("welcome-secure-storage", WelcomeScreen(mode: .restoreFailed(.secureStorage))),
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
      (
        "welcome-session-check-failed-regular",
        WelcomeScreen(mode: .restoreFailed(.sessionCheck), deviceNoun: .iPad)
      ),
      (
        "welcome-secure-storage-regular",
        WelcomeScreen(mode: .restoreFailed(.secureStorage), deviceNoun: .iPad)
      ),
    ]
    for (name, screen) in states {
      _ = try assertRenderingSnapshot(name: name, view: Self.pad(screen), size: Self.padSize)
    }
  }

  @MainActor
  func testDuoWelcomeKeepsClearOfTheTrailingBars() throws {
    let folded: [(String, WelcomeScreen)] = [
      ("welcome-duo-folded", WelcomeScreen(mode: .fresh, pinnedFrame: 0)),
      (
        "welcome-duo-folded-checking-session",
        WelcomeScreen(mode: .fresh, isCheckingSession: true, pinnedFrame: 0)
      ),
    ]
    for (name, screen) in folded {
      _ = try assertRenderingSnapshot(
        name: name,
        view: Self.device(
          screen, top: 20, bottom: 20, trailing: Self.duoTrailingBar, sizeClass: .compact),
        size: Self.duoFoldedSize
      )
    }
    _ = try assertRenderingSnapshot(
      name: "welcome-duo-open",
      view: Self.device(
        WelcomeScreen(mode: .fresh, pinnedFrame: 0), top: 20, bottom: 20,
        trailing: Self.duoTrailingBar, sizeClass: .regular),
      size: Self.duoOpenSize
    )
  }

  @MainActor
  func testSessionProgressKeepsTheWordmarkAndCentresTheSpinner() throws {
    let states = [
      ("session-restoring", SessionProgressScreen(title: "Restoring your session")),
      ("session-signing-out", SessionProgressScreen(title: "Signing out")),
    ]
    for (name, screen) in states {
      _ = try assertRenderingSnapshot(name: name, view: Self.phone(screen), size: Self.phoneSize)
      _ = try assertRenderingSnapshot(
        name: "\(name)-regular", view: Self.pad(screen), size: Self.padSize)
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
      view: Self.phone(WelcomeScreen(mode: .restoreFailed(.secureStorage))),
      size: Self.phoneSize,
      dynamicTypeSize: .accessibility3
    )
  }

  private static let phoneSize = CGSize(width: 402, height: 874)
  private static let shortPhoneSize = CGSize(width: 375, height: 667)
  private static let padSize = CGSize(width: 1210, height: 834)
  private static let duoFoldedSize = CGSize(width: 466, height: 678)
  private static let duoOpenSize = CGSize(width: 951, height: 669)
  private static let duoTrailingBar: CGFloat = 64

  @MainActor
  private static func phone(
    _ screen: some View, top: CGFloat = 62, bottom: CGFloat = 34
  ) -> some View {
    device(screen, top: top, bottom: bottom, sizeClass: .compact)
  }

  @MainActor
  private static func pad(_ screen: some View) -> some View {
    device(screen, top: 24, bottom: 20, sizeClass: .regular)
  }

  @MainActor
  private static func device(
    _ screen: some View, top: CGFloat, bottom: CGFloat, trailing: CGFloat = 0,
    sizeClass: UserInterfaceSizeClass
  ) -> some View {
    screen
      .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: top) }
      .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: bottom) }
      .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: trailing) }
      .background(PutioTheme.Colors.background)
      .ignoresSafeArea()
      .environment(\.horizontalSizeClass, sizeClass)
      .tint(PutioTheme.Colors.accent)
  }
}
