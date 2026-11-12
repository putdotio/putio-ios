import PutioCore
import SwiftUI

struct DownloadSettingsView: View {
  let queue: PutioOfflineQueue

  var body: some View {
    List {
      Group {
        PutioSettingsSection(
          String(localized: "Queue"),
          footer: String(
            localized: "Downloads beyond this wait in line and start in the order you added them.")
        ) {
          PutioPickerRow(
            title: String(localized: "Downloads at the same time"),
            selection: Binding(
              get: { queue.concurrencyLimit }, set: { queue.setConcurrencyLimit($0) }),
            options: PutioOfflineQueue.concurrencyLimits
          ) { limit in
            limit.formatted()
          }
          .accessibilityIdentifier("downloads.concurrency")
        }
        PutioSettingsSection(String(localized: "Storage")) {
          PutioValueRow(
            Self.onThisDeviceTitle, value: PutioFileRowModel.sizeText(bytes: queue.storedBytes),
            valueStyle: .measurement
          )
          .accessibilityIdentifier("downloads.settings.stored")
          PutioValueRow(
            String(localized: "Free"),
            value: PutioFileRowModel.sizeText(bytes: queue.availableBytes),
            valueStyle: .measurement
          )
          .accessibilityIdentifier("downloads.settings.free")
        }
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle(String(localized: "Downloads"))
    .navigationBarTitleDisplayMode(.inline)
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .task { queue.refreshStorage() }
    .accessibilityIdentifier("downloads.settings")
  }

  private static var onThisDeviceTitle: String {
    UIDevice.current.userInterfaceIdiom == .pad
      ? String(localized: "On this iPad") : String(localized: "On this iPhone")
  }
}
