import Foundation
import StoreKit

public enum PutioReleaseChannel: Equatable, Sendable {
  case appStore
  case testFlight
  case nightly

  public static let nightlyBundleIdentifier = "io.put.nightly.ios"

  public static func resolve(
    bundleIdentifier: String?, environment: AppStore.Environment?
  ) -> PutioReleaseChannel {
    if bundleIdentifier == nightlyBundleIdentifier { return .nightly }
    return environment == .sandbox ? .testFlight : .appStore
  }

  public static func current(bundle: Bundle = .main) async -> PutioReleaseChannel {
    #if DEBUG
      return resolve(bundleIdentifier: bundle.bundleIdentifier, environment: nil)
    #else
      let environment = try? await AppTransaction.shared.payloadValue.environment
      return resolve(bundleIdentifier: bundle.bundleIdentifier, environment: environment)
    #endif
  }

  public var title: String {
    switch self {
    case .appStore: String(localized: "App Store", bundle: .module)
    case .testFlight: String(localized: "TestFlight", bundle: .module)
    case .nightly: String(localized: "Nightly", bundle: .module)
    }
  }
}

/// Version, build, and device details a support ticket needs. Nothing here
/// identifies the user or their files.
public struct PutioAppInfo: Equatable, Sendable {
  public struct Field: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let value: String
    public let valueStyle: PutioSettingValueStyle
  }

  public static let player = "AVPlayer"

  public static func shortVersion(bundle: Bundle = .main) -> String? {
    bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }

  public let version: String
  public let build: String
  public let channel: PutioReleaseChannel
  public let device: String
  public let systemName: String
  public let systemVersion: String

  public init(
    version: String, build: String, channel: PutioReleaseChannel, device: String,
    systemName: String, systemVersion: String
  ) {
    self.version = version
    self.build = build
    self.channel = channel
    self.device = device
    self.systemName = systemName
    self.systemVersion = systemVersion
  }

  public init(
    bundle: Bundle = .main, channel: PutioReleaseChannel, device: String, systemName: String,
    systemVersion: String
  ) {
    self.init(
      version: Self.shortVersion(bundle: bundle) ?? "",
      build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
      channel: channel, device: device, systemName: systemName, systemVersion: systemVersion)
  }

  public var fields: [Field] {
    [
      Field(
        id: "version", title: String(localized: "Version", bundle: .module),
        value: String(localized: "\(version) (build \(build))", bundle: .module),
        valueStyle: .measurement),
      Field(
        id: "channel", title: String(localized: "Channel", bundle: .module), value: channel.title,
        valueStyle: .text),
      Field(
        id: "device", title: String(localized: "Device", bundle: .module), value: device,
        valueStyle: .text),
      Field(id: "os", title: systemName, value: systemVersion, valueStyle: .measurement),
      Field(
        id: "player", title: String(localized: "Player", bundle: .module), value: Self.player,
        valueStyle: .text),
    ]
  }

  public var supportText: String {
    fields.map { "\($0.title): \($0.value)" }.joined(separator: "\n")
  }

  public static let supportAddress = "support@put.io"

  /// A mail link to support with the app info as the body, for a QR code a
  /// phone can act on.
  public var supportMailto: String {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = Self.supportAddress
    components.queryItems = [URLQueryItem(name: "body", value: supportText)]
    return components.string ?? "mailto:\(Self.supportAddress)"
  }
}

public struct PutioLicenseNotice: Decodable, Equatable, Identifiable, Sendable {
  public let name: String
  public let version: String?
  public let license: String
  public let copyright: String
  public let source: URL?
  public let licenseText: URL

  public var id: String { name }

  public var title: String {
    guard let version else { return name }
    return "\(name) \(version)"
  }
}

/// The open-source notices `mise run generate` bundles as
/// `OpenSourceLicenses.json`: the app first, then every package it ships.
public struct PutioLicenseManifest: Decodable, Equatable, Sendable {
  public let app: PutioLicenseNotice
  public let packages: [PutioLicenseNotice]

  public static func load(_ bundle: Bundle) -> PutioLicenseManifest? {
    do {
      guard let url = bundle.url(forResource: "OpenSourceLicenses", withExtension: "json")
      else { throw CocoaError(.fileNoSuchFile) }
      return try JSONDecoder().decode(PutioLicenseManifest.self, from: Data(contentsOf: url))
    } catch {
      assertionFailure("OpenSourceLicenses.json is unreadable; run mise run generate: \(error)")
      return nil
    }
  }

  public func notices(appVersion: String?) -> [PutioLicenseNotice] {
    let app = PutioLicenseNotice(
      name: app.name, version: appVersion, license: app.license, copyright: app.copyright,
      source: app.source, licenseText: app.licenseText)
    return [app] + packages
  }

  public static var summary: String {
    String(
      localized:
        "This app and the native components it bundles are open source. Each comes under its own license, linked below with its source code.",
      bundle: .module)
  }
}
