import PutioCore
import SwiftUI

struct TVHomeScreen: View {
  var notice: PutioInactiveAccountNotice?

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      if let notice {
        TVInactiveAccountNotice(notice: notice)
      } else {
        TVHomeEmptyState()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }
}

struct TVHomeEmptyState: View {
  static let addFilesURL = "https://app.put.io"

  var body: some View {
    VStack(spacing: PutioTheme.TV.Spacing.medium) {
      PutioEmptyStateView(
        kaomoji: .nothingYet,
        title: String(localized: "Nothing here yet.", bundle: .putioCore),
        message: String(
          localized: "Scan to add files from your phone. What you watch and pin shows up here.",
          bundle: .putioCore)
      )
      .fixedSize(horizontal: false, vertical: true)
      PutioQRCodeView(Self.addFilesURL, size: 240)
        .accessibilityElement()
        .accessibilityLabel(Text("QR code that opens put.io", bundle: .putioCore))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .focusable()
    .focusEffectDisabled()
    .accessibilityIdentifier("home.empty")
  }
}
