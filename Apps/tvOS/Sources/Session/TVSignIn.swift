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

  var body: some View {
    TVSignInScreen(
      phase: TVSignInPhase(state: session.state, deviceCodeSignIn: session.deviceCodeSignIn),
      sessionExpired: PutioSignedOutNotice(
        reason: session.state == .signedOut(.sessionExpired) ? .sessionExpired : nil,
        device: .appleTV),
      requestCode: { Task { await session.signInWithDeviceCode() } },
      retryRestore: { Task { await session.restore() } },
      discardCredential: { session.discardUnrestoredCredential() }
    )
    // A fresh signed-out screen asks for a code on its own; failures wait for
    // an explicit retry so an unreachable API cannot loop.
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
    VStack(spacing: PutioTheme.TV.Spacing.medium) {
      Text("put.io")
        .putioFont(PutioTheme.TV.Typography.heading)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
      if let sessionExpired {
        Text(verbatim: "\(sessionExpired.title). \(sessionExpired.message)")
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.destructive)
      }
      VStack(spacing: PutioTheme.TV.Spacing.xs) {
        Text("On your phone or computer, go to")
          .putioFont(PutioTheme.TV.Typography.body)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        Text("put.io/link")
          .putioFont(PutioTheme.TV.Typography.label)
          .foregroundStyle(PutioTheme.Colors.accent)
        Text("and enter this code")
          .putioFont(PutioTheme.TV.Typography.body)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      }
      .multilineTextAlignment(.center)
      HStack(spacing: PutioTheme.TV.Spacing.large) {
        if let qrCode = phase.deviceCode?.qrCode {
          TVSignInQRCode(png: qrCode, isDimmed: phase.isExpired)
        }
        codeBlock
      }
      status
    }
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }

  private var codeBlock: some View {
    Group {
      switch phase {
      case .awaitingApproval(let code):
        codeText(code.code, color: PutioTheme.TV.Colors.textPrimary)
      case .expired(let code):
        codeText(code.code, color: PutioTheme.TV.Colors.textTertiary)
      case .fetchingCode, .failed:
        codeText("·····", color: PutioTheme.TV.Colors.textTertiary)
      }
    }
    .padding(.vertical, PutioTheme.TV.Spacing.small)
    .padding(.horizontal, PutioTheme.TV.Spacing.large)
    .background(
      RoundedRectangle(cornerRadius: PutioTheme.TV.radius, style: .continuous)
        .fill(PutioTheme.Colors.surface)
    )
  }

  private func codeText(_ code: String, color: Color) -> some View {
    Text(code)
      .putioFont(PutioTabularFontRole(base: PutioTheme.TV.Typography.heading))
      .tracking(PutioTheme.TV.Spacing.small)
      .foregroundStyle(color)
      .accessibilityIdentifier("auth.device-code")
      .accessibilityValue(code)
  }

  @ViewBuilder
  private var status: some View {
    switch phase {
    case .fetchingCode:
      TVSignInStatus(text: "Getting a code…", identifier: "auth.fetching-code")
    case .awaitingApproval:
      VStack(spacing: PutioTheme.TV.Spacing.small) {
        TVSignInStatus(text: "Waiting for approval…", identifier: "auth.awaiting-approval")
        PutioButton("Get new code", tier: .secondary) {
          requestCode()
        }
        .accessibilityIdentifier("auth.new-code")
      }
    case .expired:
      VStack(spacing: PutioTheme.TV.Spacing.small) {
        Text("This code expired.")
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.destructive)
          .accessibilityIdentifier("auth.code-expired")
        PutioButton("Get new code", tier: .primary) {
          requestCode()
        }
        .accessibilityIdentifier("auth.new-code")
      }
    case .failed(let notice):
      VStack(spacing: PutioTheme.TV.Spacing.small) {
        Text(notice.title)
          .putioFont(PutioTheme.TV.Typography.label)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
          .multilineTextAlignment(.center)
        Text(notice.message)
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.destructive)
          .multilineTextAlignment(.center)
          .accessibilityIdentifier("auth.failure")
        if let actions = notice.restoreActions {
          PutioButton(actions.retryTitle, tier: .primary, action: retryRestore)
            .accessibilityIdentifier("auth.retry")
          // Abandoning the saved sign-in is only ever the user's choice; a
          // transient failure must not cost a valid session.
          PutioButton(actions.discardTitle, tier: .secondary) {
            discardCredential()
          }
          .accessibilityIdentifier("auth.discard-credential")
          Text("Signing in again removes the saved sign-in from this Apple TV.")
            .putioFont(PutioTheme.TV.Typography.caption)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
            .multilineTextAlignment(.center)
        } else {
          PutioButton("Try again", tier: .primary, action: requestCode)
            .accessibilityIdentifier("auth.retry")
        }
      }
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
        .background(.white, in: RoundedRectangle(cornerRadius: PutioTheme.TV.radius))
        .opacity(isDimmed ? TVSignInLayout.dimmedOpacity : 1)
        .accessibilityElement()
        .accessibilityLabel("QR code to sign in on your phone")
        .accessibilityIdentifier("auth.qr-code")
    }
  }
}

enum TVSignInLayout {
  static let qrSize: CGFloat = 300
  static let qrPaddingRatio: CGFloat = 0.06
  static let dimmedOpacity = 0.3
}

private struct TVSignInStatus: View {
  let text: String
  let identifier: String

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      ProgressView()
      Text(text)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .accessibilityIdentifier(identifier)
    }
  }
}
