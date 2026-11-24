import PutioCore
import SwiftUI

extension PutioDevice {
  @MainActor static var current: PutioDevice {
    UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
  }
}

extension PutioAppInfo {
  @MainActor static func current(channel: PutioReleaseChannel) -> PutioAppInfo {
    PutioAppInfo(
      channel: channel, device: UIDevice.current.model, systemName: "iOS",
      systemVersion: UIDevice.current.systemVersion)
  }
}

extension PutioLicenseManifest {
  static let bundled: PutioLicenseManifest? = load(.main)
}

struct AppInfoView: View {
  @State private var channel = PutioReleaseChannel.resolve(
    bundleIdentifier: Bundle.main.bundleIdentifier, environment: nil)
  @State private var toast: PutioToast?

  var body: some View {
    List {
      Group {
        let info = PutioAppInfo.current(channel: channel)
        PutioSettingsSection(
          String(localized: "Version, build, and device details for support."),
          footer: String(
            localized:
              "Nothing here identifies you or your files. Paste it into a support ticket.")
        ) {
          ForEach(info.fields) { field in
            PutioValueRow(field.title, value: field.value, valueStyle: field.valueStyle)
              .accessibilityIdentifier("app-info.\(field.id)")
          }
        }
        Section {
          Button {
            UIPasteboard.general.string = info.supportText
            toast = PutioToast(String(localized: "Copied to clipboard"), width: .fit)
          } label: {
            Text(String(localized: "Copy for support"))
              .putioFont(PutioTheme.Typography.body)
              .foregroundStyle(PutioTheme.Colors.textPrimary)
              .frame(maxWidth: .infinity)
              .contentShape(Rectangle())
          }
          .accessibilityIdentifier("app-info.copy")
        }
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle(String(localized: "App info"))
    .navigationBarTitleDisplayMode(.inline)
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .putioToast($toast)
    .task { channel = await PutioReleaseChannel.current() }
  }
}

struct OpenSourceLicensesView: View {
  @Environment(\.openURL) private var openURL
  private var notices: [PutioLicenseNotice] {
    PutioLicenseManifest.bundled?.notices(appVersion: PutioAppInfo.shortVersion()) ?? []
  }

  var body: some View {
    List {
      ForEach(Array(notices.enumerated()), id: \.element.id) { index, notice in
        PutioSettingsSection(index == 0 ? PutioLicenseManifest.summary : nil) {
          VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
            Text(notice.title)
              .putioFont(PutioTheme.Typography.body)
              .foregroundStyle(PutioTheme.Colors.textPrimary)
            Group {
              Text(notice.license)
              Text(notice.copyright)
            }
            .putioFont(PutioTheme.Typography.caption)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("licenses.notice")
          if let source = notice.source {
            PutioLinkRow(String(localized: "Source code")) { openURL(source) }
          }
          PutioLinkRow(String(localized: "License text")) { openURL(notice.licenseText) }
        }
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle(String(localized: "Open source licenses"))
    .navigationBarTitleDisplayMode(.inline)
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
  }
}
