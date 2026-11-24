import PutioCore
import SwiftUI
import UIKit

/// What the code screen shows, derived from the session store so the view
/// owns no flow state of its own.
enum TVSignInPhase: Equatable {
  case fetchingCode
  case awaitingApproval(PutioDeviceCode)
  case expired(PutioDeviceCode)
  case failed(PutioSignedOutNotice)

  init(state: PutioSessionState, deviceCodeSignIn: PutioDeviceCodeSignInState?) {
    switch state {
    case .signedOut(let reason):
      if let notice = PutioSignedOutNotice(reason: reason, device: .appleTV),
        notice.kind != .sessionExpired
      {
        self = .failed(notice)
      } else {
        self = .fetchingCode
      }
    case .authenticating:
      switch deviceCodeSignIn {
      case .awaitingApproval(let code): self = .awaitingApproval(code)
      case .expired(let code): self = .expired(code)
      case .fetchingCode, nil: self = .fetchingCode
      }
    default:
      self = .fetchingCode
    }
  }
}

struct TVSignInView: View {
  let session: PutioSessionStore
  var restoreRetryInterval: Duration = .seconds(15)
  @State private var sessionExpired = false

  var body: some View {
    TVSignInScreen(
      phase: TVSignInPhase(state: session.state, deviceCodeSignIn: session.deviceCodeSignIn),
      sessionExpired: PutioSignedOutNotice(
        reason: sessionExpired ? .sessionExpired : nil, device: .appleTV),
      requestCode: { Task { await session.signInWithDeviceCode() } },
      retryRestore: { Task { await session.restore() } },
      discardCredential: { session.discardUnrestoredCredential() }
    )
    // A fresh signed-out screen asks for a code on its own; failures wait for
    // an explicit retry so an unreachable API cannot loop.
    .onChange(of: session.state, initial: true) { _, state in
      if state == .signedOut(.sessionExpired) { sessionExpired = true }
    }
    .onChange(of: startsAutomatically, initial: true) { _, starts in
      if starts { Task { await session.signInWithDeviceCode() } }
    }
    .task(id: retriesRestore) {
      guard retriesRestore else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: restoreRetryInterval)
        guard !Task.isCancelled else { return }
        await session.restore()
      }
    }
  }

  private var retriesRestore: Bool {
    if case .signedOut(.restoreFailed(.sessionCheck, _)) = session.state { return true }
    return false
  }

  private var startsAutomatically: Bool {
    switch session.state {
    case .signedOut(nil), .signedOut(.userSignedOut), .signedOut(.sessionExpired): true
    default: false
    }
  }
}

struct TVSignInScreen: View {
  let phase: TVSignInPhase
  var sessionExpired: PutioSignedOutNotice?
  let requestCode: () -> Void
  let retryRestore: () -> Void
  var discardCredential: () -> Void = {}

  var body: some View {
    Group {
      if case .failed(let notice) = phase {
        TVSignInFailure(
          notice: notice, requestCode: requestCode, retryRestore: retryRestore,
          discardCredential: discardCredential)
      } else {
        linkScreen
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }

  private var linkScreen: some View {
    VStack(spacing: PutioTheme.TV.Spacing.large) {
      VStack(spacing: PutioTheme.TV.Spacing.small) {
        TVSignInGreeting()
        Text(sessionExpired?.title ?? String(localized: "Sign in to put.io", bundle: .putioCore))
          .putioFont(PutioTheme.TV.Typography.heading)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        if let sessionExpired {
          Text(sessionExpired.message)
            .putioFont(PutioTheme.TV.Typography.caption)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
            .accessibilityIdentifier("auth.session-expired")
        }
      }
      HStack(alignment: .center, spacing: 0) {
        phoneColumn
          .frame(maxWidth: .infinity)
        TVSignInDivider()
        browserColumn
          .frame(maxWidth: .infinity)
      }
      .frame(maxHeight: .infinity, alignment: .top)
    }
  }

  private var phoneColumn: some View {
    VStack(spacing: PutioTheme.TV.Spacing.medium) {
      TVSignInColumnTitle(String(localized: "With your phone", bundle: .putioCore))
      Group {
        if let qrCode = phase.deviceCode?.qrCode {
          TVSignInQRCode(png: qrCode, isDimmed: phase.isExpired)
        } else {
          RoundedRectangle(cornerRadius: TVSignInLayout.qrCornerRadius, style: .continuous)
            .fill(PutioTheme.Colors.surface)
            .frame(width: TVSignInLayout.qrSize, height: TVSignInLayout.qrSize)
        }
      }
      Text("Scan with your camera and approve.", bundle: .putioCore)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .multilineTextAlignment(.center)
    }
  }

  private var browserColumn: some View {
    VStack(spacing: PutioTheme.TV.Spacing.medium) {
      TVSignInColumnTitle(String(localized: "In a browser", bundle: .putioCore))
      Text(Self.linkInstruction)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .multilineTextAlignment(.center)
      status
      TVSignInCodeTiles(code: phase.deviceCode?.code, isDimmed: phase.isExpired)
      PutioButton(
        String(localized: "Get a new code", bundle: .putioCore), icon: .arrowCounterClockwise,
        tier: .primary, action: requestCode
      )
      .disabled(phase.deviceCode == nil)
      .accessibilityIdentifier("auth.new-code")
    }
  }

  static var linkInstruction: AttributedString {
    let link = String(localized: "put.io/link", bundle: .putioCore)
    var text = AttributedString(
      String(localized: "Go to \(link) and enter", bundle: .putioCore))
    if let range = text.range(of: link) {
      text[range].foregroundColor = PutioTheme.Colors.accent
      text[range].font = PutioTheme.TV.Typography.caption.font.weight(.medium)
    }
    return text
  }

  @ViewBuilder
  private var status: some View {
    switch phase {
    case .fetchingCode:
      TVSignInStatus(
        String(localized: "Getting a code", bundle: .putioCore), identifier: "auth.fetching-code")
    case .awaitingApproval(let code) where code.isOffline:
      TVSignInStatus(
        String(localized: "No connection. Still trying.", bundle: .putioCore),
        identifier: "auth.offline", icon: .wifiSlash)
    case .awaitingApproval:
      TVSignInStatus(
        String(localized: "Waiting for authentication…", bundle: .putioCore),
        identifier: "auth.awaiting-approval")
    case .expired:
      Text("This code expired.", bundle: .putioCore)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .accessibilityIdentifier("auth.code-expired")
    case .failed:
      EmptyView()
    }
  }
}

extension TVSignInPhase {
  var deviceCode: PutioDeviceCode? {
    switch self {
    case .awaitingApproval(let code), .expired(let code): code
    case .fetchingCode, .failed: nil
    }
  }

  var isExpired: Bool {
    if case .expired = self { return true }
    return false
  }
}

/// The launch check of a saved sign-in, before the shell or sign-in shows.
struct TVSessionCheckingView: View {
  var body: some View {
    VStack(spacing: PutioTheme.TV.Spacing.medium) {
      TVSignInWordmark()
      Spacer()
      PutioLoadingStateView(title: String(localized: "Checking your session", bundle: .putioCore))
        .fixedSize()
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }
}

private struct TVSignInFailure: View {
  let notice: PutioSignedOutNotice
  let requestCode: () -> Void
  let retryRestore: () -> Void
  let discardCredential: () -> Void

  var body: some View {
    VStack(spacing: PutioTheme.TV.Spacing.medium) {
      TVSignInWordmark()
      Spacer()
      Text(verbatim: PutioKaomoji.knockedOut.rawValue)
        .putioFont(PutioTVTypeScale.kaomoji)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .accessibilityHidden(true)
      VStack(spacing: PutioTheme.TV.Spacing.small) {
        Text(notice.title)
          .putioFont(PutioTheme.TV.Typography.label)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        Text(notice.message)
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          .accessibilityIdentifier("auth.failure")
      }
      .multilineTextAlignment(.center)
      if let actions = notice.restoreActions {
        PutioButton(
          actions.retryTitle, icon: .arrowCounterClockwise, tier: .primary, action: retryRestore
        )
        .accessibilityIdentifier("auth.retry")
        PutioButton(actions.discardTitle, tier: .secondary, action: discardCredential)
          .accessibilityIdentifier("auth.discard-credential")
      } else {
        PutioButton(
          String(localized: "Try again", bundle: .putioCore), icon: .arrowCounterClockwise,
          tier: .primary, action: requestCode
        )
        .accessibilityIdentifier("auth.retry")
      }
      Spacer()
    }
  }
}

private struct TVSignInGreeting: View {
  var body: some View {
    VStack(spacing: PutioTheme.TV.Spacing.xs) {
      Text(verbatim: TVSignInLayout.greetingKaomoji)
        .putioFont(PutioTVTypeScale.kaomoji)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
      Text("Paste a magnet.", bundle: .putioCore)
        .putioFont(PutioTVTypeScale.tagline)
        .foregroundStyle(PutioTheme.Colors.accent)
    }
    .accessibilityHidden(true)
  }
}

private struct TVSignInWordmark: View {
  var body: some View {
    Image.putioWordmark
      .resizable()
      .scaledToFit()
      .frame(height: TVSignInLayout.wordmarkHeight)
      .accessibilityLabel(Text(verbatim: "put.io"))
  }
}

private struct TVSignInColumnTitle: View {
  let title: String

  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title)
      .putioFont(PutioTVTypeScale.columnTitle)
      .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
  }
}

private struct TVSignInDivider: View {
  var body: some View {
    VStack(spacing: PutioTheme.TV.Spacing.small) {
      line
      Text("or", bundle: .putioCore)
        .putioFont(PutioTheme.TV.Typography.small)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      line
    }
    .accessibilityHidden(true)
  }

  private var line: some View {
    Rectangle()
      .fill(PutioTheme.Colors.separator)
      .frame(width: 2)
      .frame(maxHeight: .infinity)
  }
}

/// The activation code as one tile per letter, dimmed once it expires.
private struct TVSignInCodeTiles: View {
  let code: String?
  let isDimmed: Bool

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.xs) {
      ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
        Text(verbatim: letter)
          .putioFont(PutioTabularFontRole(base: PutioTheme.TV.Typography.heading))
          .foregroundStyle(
            isDimmed || code == nil
              ? PutioTheme.TV.Colors.textTertiary.opacity(TVSignInLayout.dimmedOpacity)
              : PutioTheme.TV.Colors.textPrimary
          )
          .frame(width: TVSignInLayout.tileWidth, height: TVSignInLayout.tileHeight)
          .background(
            PutioTheme.Colors.surface.opacity(isDimmed ? TVSignInLayout.dimmedOpacity * 2 : 1),
            in: RoundedRectangle(cornerRadius: PutioTheme.TV.radius, style: .continuous))
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: code ?? ""))
    .accessibilityIdentifier("auth.device-code")
    .accessibilityValue(code ?? "")
  }

  private var letters: [String] {
    guard let code else {
      return Array(repeating: " ", count: TVSignInLayout.placeholderLength)
    }
    return code.map(String.init)
  }
}

/// put.io's QR image for the code on screen, scaled without smoothing so its
/// modules stay sharp. An image that does not decode shows nothing.
struct TVSignInQRCode: View {
  let png: Data
  var isDimmed = false

  var body: some View {
    if let image = UIImage(data: png) {
      Image(uiImage: image)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .padding(TVSignInLayout.qrSize * TVSignInLayout.qrPaddingRatio)
        .frame(width: TVSignInLayout.qrSize, height: TVSignInLayout.qrSize)
        .background(
          TVSignInLayout.qrBackground,
          in: RoundedRectangle(cornerRadius: TVSignInLayout.qrCornerRadius, style: .continuous)
        )
        .opacity(isDimmed ? TVSignInLayout.dimmedOpacity : 1)
        .accessibilityElement()
        .accessibilityLabel(Text("QR code to sign in on your phone", bundle: .putioCore))
        .accessibilityIdentifier("auth.qr-code")
    }
  }
}

enum TVSignInLayout {
  static let qrSize: CGFloat = 300
  static let qrPaddingRatio: CGFloat = 0.12
  static let qrCornerRadius: CGFloat = 36
  static let qrBackground = Color(.sRGB, red: 0.925, green: 0.925, blue: 0.925, opacity: 1)
  static let dimmedOpacity = 0.3
  static let tileWidth: CGFloat = 92
  static let tileHeight: CGFloat = 116
  static let placeholderLength = 6
  static let statusIconSize: CGFloat = 32
  static let wordmarkHeight: CGFloat = 48
  static let greetingKaomoji = "┌( ಠ‿ಠ)┘"
}

private struct TVSignInStatus: View {
  let text: String
  let identifier: String
  var icon: PutioIcon?

  init(_ text: String, identifier: String, icon: PutioIcon? = nil) {
    self.text = text
    self.identifier = identifier
    self.icon = icon
  }

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      if let icon {
        Image(putioIcon: icon)
          .resizable()
          .scaledToFit()
          .frame(width: TVSignInLayout.statusIconSize, height: TVSignInLayout.statusIconSize)
          .foregroundStyle(PutioTheme.Colors.accent)
          .accessibilityHidden(true)
      } else {
        ProgressView()
      }
      Text(text)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .accessibilityIdentifier(identifier)
    }
  }
}
