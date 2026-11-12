import PutioCore
import StoreKit
import SwiftUI

enum PutioReleaseChannel: Equatable {
  case appStore
  case testFlight
  case nightly

  static let nightlyBundleIdentifier = "io.put.nightly.ios"

  static func resolve(
    bundleIdentifier: String?, environment: AppStore.Environment?
  ) -> PutioReleaseChannel {
    if bundleIdentifier == nightlyBundleIdentifier { return .nightly }
    return environment == .sandbox ? .testFlight : .appStore
  }

  static func current(bundle: Bundle = .main) async -> PutioReleaseChannel {
    #if DEBUG
      return resolve(bundleIdentifier: bundle.bundleIdentifier, environment: nil)
    #else
      let environment = try? await AppTransaction.shared.payloadValue.environment
      return resolve(bundleIdentifier: bundle.bundleIdentifier, environment: environment)
    #endif
  }

  var title: String {
    switch self {
    case .appStore: String(localized: "App Store")
    case .testFlight: String(localized: "TestFlight")
    case .nightly: String(localized: "Nightly")
    }
  }
}

struct PutioAppInfo: Equatable {
  struct Field: Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let valueStyle: PutioSettingValueStyle
  }

  static let player = "AVPlayer"

  static var shortVersion: String? {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }

  let version: String
  let build: String
  let channel: PutioReleaseChannel
  let device: String
  let systemVersion: String

  @MainActor static func current(channel: PutioReleaseChannel, bundle: Bundle = .main)
    -> PutioAppInfo
  {
    PutioAppInfo(
      version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
      build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
      channel: channel,
      device: UIDevice.current.model,
      systemVersion: UIDevice.current.systemVersion
    )
  }

  var fields: [Field] {
    [
      Field(
        id: "version", title: String(localized: "Version"),
        value: String(localized: "\(version) (build \(build))"), valueStyle: .measurement),
      Field(
        id: "channel", title: String(localized: "Channel"), value: channel.title, valueStyle: .text),
      Field(id: "device", title: String(localized: "Device"), value: device, valueStyle: .text),
      Field(
        id: "os", title: String(localized: "iOS"), value: systemVersion, valueStyle: .measurement),
      Field(
        id: "player", title: String(localized: "Player"), value: Self.player, valueStyle: .text),
    ]
  }

  var supportText: String {
    fields.map { "\($0.title): \($0.value)" }.joined(separator: "\n")
  }
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
            toast = PutioToast(String(localized: "Copied to clipboard"))
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

struct PutioLicenseNotice: Decodable, Equatable, Identifiable {
  let name: String
  let version: String?
  let license: String
  let copyright: String
  let source: URL?
  let licenseText: URL

  var id: String { name }

  var title: String {
    guard let version else { return name }
    return "\(name) \(version)"
  }
}

struct PutioLicenseManifest: Decodable, Equatable {
  let app: PutioLicenseNotice
  let packages: [PutioLicenseNotice]

  static let bundled: PutioLicenseManifest? = load(.main)

  static func load(_ bundle: Bundle) -> PutioLicenseManifest? {
    do {
      guard let url = bundle.url(forResource: "OpenSourceLicenses", withExtension: "json")
      else { throw CocoaError(.fileNoSuchFile) }
      return try JSONDecoder().decode(PutioLicenseManifest.self, from: Data(contentsOf: url))
    } catch {
      assertionFailure("OpenSourceLicenses.json is unreadable; run mise run generate: \(error)")
      return nil
    }
  }

  func notices(appVersion: String?) -> [PutioLicenseNotice] {
    let app = PutioLicenseNotice(
      name: app.name, version: appVersion, license: app.license, copyright: app.copyright,
      source: app.source, licenseText: app.licenseText)
    return [app] + packages
  }
}

struct OpenSourceLicensesView: View {
  @Environment(\.openURL) private var openURL
  private var notices: [PutioLicenseNotice] {
    PutioLicenseManifest.bundled?.notices(appVersion: PutioAppInfo.shortVersion) ?? []
  }

  var body: some View {
    List {
      ForEach(Array(notices.enumerated()), id: \.element.id) { index, notice in
        PutioSettingsSection(
          index == 0
            ? String(
              localized:
                "This app and the native components it bundles are open source. Each comes under its own license, linked below with its source code."
            ) : nil
        ) {
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
