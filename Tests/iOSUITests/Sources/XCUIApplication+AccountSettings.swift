import XCTest

extension XCUIApplication {
  func releaseAccountSettingsLoads() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName("io.put.harness.account-settings-release" as CFString), nil, nil, true)
  }
}
