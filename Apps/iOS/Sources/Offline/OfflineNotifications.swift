import Observation
import PutioCore
import SwiftUI
import UIKit
import UserNotifications

enum PutioOfflineNotifications {
  static let deniedArgument = "--putio-harness-notifications-denied"

  static func requestPermissionIfNeeded(center: UNUserNotificationCenter = .current()) async {
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .notDetermined else { return }
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  static func authorizationStatus() async -> UNAuthorizationStatus {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains(deniedArgument) { return .denied }
    #endif
    return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }

  static func notifyCompletion(
    _ item: PutioOfflineItem, center: UNUserNotificationCenter = .current()
  ) {
    let content = UNMutableNotificationContent()
    content.title = String(localized: "Download finished")
    content.body = item.name
    post(content, for: item, center: center)
  }

  static func notifyFailure(
    _ item: PutioOfflineItem, _ failure: PutioOfflineFailure,
    center: UNUserNotificationCenter = .current()
  ) {
    let content = UNMutableNotificationContent()
    content.title = String(localized: "Download failed")
    content.subtitle = item.name
    content.body = failure.message
    post(content, for: item, center: center)
  }

  private static func post(
    _ content: UNMutableNotificationContent, for item: PutioOfflineItem,
    center: UNUserNotificationCenter
  ) {
    let request = UNNotificationRequest(
      identifier: "offline-\(item.id.rawValue)", content: content, trigger: nil)
    center.add(request)
  }
}

@MainActor
@Observable
final class PutioOfflineNotificationStatus {
  private(set) var isOff = false
  @ObservationIgnored private let readStatus: @MainActor () async -> UNAuthorizationStatus

  init(
    readStatus: @escaping @MainActor () async -> UNAuthorizationStatus =
      PutioOfflineNotifications.authorizationStatus
  ) {
    self.readStatus = readStatus
  }

  func refresh() async {
    isOff = await readStatus() == .denied
  }

  func showsRow(hasDownloads: Bool) -> Bool {
    hasDownloads && isOff
  }
}

struct PutioOfflineNotificationsOffRow: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    HStack(spacing: PutioTheme.Spacing.space3) {
      Text("Download notifications are off")
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Turn on") {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else {
          return
        }
        openURL(url)
      }
      .putioFont(PutioTheme.Components.Button.label)
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .tint(PutioTheme.Colors.textPrimary)
      .accessibilityIdentifier("downloads.notifications-turn-on")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("downloads.notifications-off")
  }
}
