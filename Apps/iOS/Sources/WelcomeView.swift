import AuthenticationServices
import PutioCore
import SwiftUI

/// The signed-out phone screen (mobile-s00-welcome): the retro wordmark in the
/// navigation-bar slot, the kaomoji lockup anchored in the upper third, and a
/// single action pinned above the bottom safe area.
struct WelcomeScreen: View {
  enum Mode: Equatable {
    case fresh
    case sessionExpired
    case signInFailed(String)
    case restoreFailed(String)
  }

  let mode: Mode
  var signIn: () -> Void = {}
  var retryRestore: () -> Void = {}
  var discardCredential: () -> Void = {}

  @PutioScaledMetric(WelcomeMetrics.kaomojiGap) private var kaomojiGap
  @PutioScaledMetric(WelcomeMetrics.ledeGap) private var ledeGap
  @PutioScaledMetric(WelcomeMetrics.detailGap) private var detailGap

  var body: some View {
    ScrollView {
      copy
        .padding(.top, PutioTheme.Spacing.space6)
        .padding(.horizontal, WelcomeMetrics.sideMargin)
        .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .top, spacing: 0) { header }
    .safeAreaInset(edge: .bottom, spacing: 0) { actions }
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }

  private var header: some View {
    Image.putioWordmark
      .resizable()
      .scaledToFit()
      .frame(width: WelcomeMetrics.wordmarkWidth)
      .frame(maxWidth: .infinity)
      .frame(height: WelcomeMetrics.headerHeight)
      .accessibilityLabel("put.io")
      .accessibilityRemoveTraits(.isImage)
  }

  private var copy: some View {
    VStack(spacing: 0) {
      Text(verbatim: "┌( ಠ‿ಠ)┘")
        .welcomeFont(WelcomeTypography.kaomoji)
        .tracking(WelcomeTypography.kaomoji.size * 0.02)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .accessibilityHidden(true)
        .padding(.bottom, kaomojiGap)
      Text(title)
        .welcomeFont(WelcomeTypography.title)
        .tracking(WelcomeTypography.title.size * -0.02)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("auth.welcome-title")
      if let lede {
        Text(lede)
          .welcomeFont(WelcomeTypography.lede)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .frame(maxWidth: WelcomeMetrics.ledeMaxWidth)
          .padding(.top, ledeGap)
      }
      if mode != .fresh {
        detail
          .padding(.top, detailGap)
      }
    }
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var detail: some View {
    switch mode {
    case .fresh:
      EmptyView()
    case .sessionExpired:
      WelcomeNotice(
        icon: .clockCountdown,
        tint: PutioTheme.Colors.accent,
        message: "Your session expired. Sign in again to continue."
      )
    case .signInFailed(let message):
      WelcomeNotice(icon: .warningCircle, tint: PutioTheme.Colors.destructive, message: message)
    case .restoreFailed(let message):
      WelcomeNotice(
        icon: .warningCircle,
        tint: PutioTheme.Colors.destructive,
        message: message,
        footnote: "Signing in again removes the saved sign-in from this device."
      )
    }
  }

  private var actions: some View {
    VStack(spacing: PutioTheme.Spacing.space2) {
      switch mode {
      case .fresh, .sessionExpired:
        WelcomeButton("Sign in", prominent: true, action: signIn)
          .accessibilityIdentifier("auth.sign-in")
      case .signInFailed:
        WelcomeButton("Try again", prominent: true, action: signIn)
          .accessibilityIdentifier("auth.sign-in")
      case .restoreFailed:
        WelcomeButton("Try again", prominent: true, action: retryRestore)
          .accessibilityIdentifier("auth.retry")
        // Abandoning the saved sign-in is only ever the user's choice; a
        // transient failure must not cost a valid session.
        WelcomeButton("Sign in again", prominent: false, action: discardCredential)
          .accessibilityIdentifier("auth.discard-credential")
      }
    }
    .padding(.horizontal, WelcomeMetrics.sideMargin)
    .padding(.bottom, PutioTheme.Spacing.space3)
    .background(PutioTheme.Colors.background)
  }

  private var title: String {
    switch mode {
    case .fresh, .signInFailed, .restoreFailed: "Welcome!"
    case .sessionExpired: "Welcome back!"
    }
  }

  private var lede: String? {
    switch mode {
    case .fresh: "Sign in to stream, download and manage your files."
    case .sessionExpired, .signInFailed, .restoreFailed: nil
    }
  }
}

extension WelcomeScreen.Mode {
  init(reason: PutioSignedOutReason?) {
    switch reason {
    case nil, .userSignedOut: self = .fresh
    case .sessionExpired: self = .sessionExpired
    case .authenticationFailed(let message): self = .signInFailed(message)
    case .restoreFailed(let message): self = .restoreFailed(message)
    }
  }
}

/// Owns the OAuth hand-off. ASWebAuthenticationSession presents its own modal
/// and reports cancellation through its callback, so the welcome screen stays
/// underneath in the mode it had when sign-in started.
struct SignInView: View {
  let session: PutioSessionStore
  let scenario: HarnessScenario

  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @State private var lastMode = WelcomeScreen.Mode.fresh

  var body: some View {
    WelcomeScreen(
      mode: mode,
      signIn: { Task { await startSignIn() } },
      retryRestore: { Task { await session.restore() } },
      discardCredential: {
        session.discardUnrestoredCredential()
        Task { await startSignIn() }
      }
    )
    .onChange(of: session.state, initial: true) { _, state in
      if case .signedOut(let reason) = state { lastMode = WelcomeScreen.Mode(reason: reason) }
    }
  }

  private var mode: WelcomeScreen.Mode {
    if case .signedOut(let reason) = session.state { return WelcomeScreen.Mode(reason: reason) }
    return lastMode
  }

  private func startSignIn() async {
    #if DEBUG
      // Live harness runs cannot drive the web login; the harness approves
      // the device code instead.
      if scenario == .live {
        await session.signInWithDeviceCode()
        return
      }
    #endif
    do {
      let request = try session.beginSignIn()
      #if DEBUG
        if scenario == .filesBrowser {
          let callbackURL = try PutioRuntimeFactory.runtimeProofCallback(for: request)
          await session.completeSignIn(callbackURL: callbackURL)
          return
        }
      #endif
      let callbackURL = try await webAuthenticationSession.authenticate(
        using: request.url,
        callbackURLScheme: request.callbackScheme
      )
      await session.completeSignIn(callbackURL: callbackURL)
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      session.cancelSignIn()
    } catch {
      session.failSignIn(error)
    }
  }
}

private struct WelcomeNotice: View {
  let icon: PutioIcon
  let tint: Color
  let message: String
  var footnote: String?

  @ScaledMetric(relativeTo: .subheadline) private var textSize = WelcomeTypography.notice.size

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: PutioTheme.Spacing.space2) {
      PutioIconView(icon, size: WelcomeMetrics.noticeIcon)
        .foregroundStyle(tint)
        // Centre the glyph on the first line's cap height, not the block.
        .alignmentGuide(.firstTextBaseline) { dimensions in
          dimensions[VerticalAlignment.center] + capHeight / 2
        }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
        Text(message)
        if let footnote {
          Text(footnote).foregroundStyle(PutioTheme.Colors.textSecondary)
        }
      }
      .welcomeFont(WelcomeTypography.notice)
      .foregroundStyle(PutioTheme.Colors.textPrimary)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, PutioTheme.Spacing.space3)
    .background(
      PutioTheme.Colors.surface,
      in: .rect(cornerRadius: WelcomeMetrics.noticeRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WelcomeMetrics.noticeRadius)
        .strokeBorder(
          PutioTheme.Colors.separator, lineWidth: PutioTheme.Border.width)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("auth.notice")
  }

  private var capHeight: CGFloat {
    let font =
      UIFont(name: WelcomeTypography.notice.fontName, size: textSize)
      ?? .systemFont(ofSize: textSize)
    return font.capHeight
  }
}

private struct WelcomeButton: View {
  let title: String
  let prominent: Bool
  let action: () -> Void

  init(_ title: String, prominent: Bool, action: @escaping () -> Void) {
    self.title = title
    self.prominent = prominent
    self.action = action
  }

  var body: some View {
    if prominent {
      Button(action: action) {
        label.foregroundStyle(PutioTheme.Components.Button.primaryForeground)
      }
      .buttonStyle(.borderedProminent)
      .modifier(WelcomeButtonShape())
    } else {
      Button(action: action) { label }
        .buttonStyle(.bordered)
        .modifier(WelcomeButtonShape())
    }
  }

  private var label: some View {
    Text(title)
      .welcomeFont(WelcomeTypography.button)
      .frame(maxWidth: .infinity)
  }
}

private struct WelcomeButtonShape: ViewModifier {
  func body(content: Content) -> some View {
    content
      .controlSize(.large)
      .buttonBorderShape(.capsule)
      .tint(PutioTheme.Colors.accent)
  }
}

// `putioFont` adds `size * (lineHeight - 1)` on top of the face's natural line
// height; the mock's line heights are CSS totals, so subtract the natural one.
private struct WelcomeFontModifier: ViewModifier {
  let role: PutioFontRole
  @ScaledMetric private var size: CGFloat

  init(role: PutioFontRole) {
    self.role = role
    _size = ScaledMetric(wrappedValue: role.size, relativeTo: role.textStyle)
  }

  func body(content: Content) -> some View {
    let font = UIFont(name: role.fontName, size: size) ?? .systemFont(ofSize: size)
    content
      .font(role.font)
      .lineSpacing(max(0, size * role.lineHeight - font.lineHeight))
  }
}

extension View {
  fileprivate func welcomeFont(_ role: PutioFontRole) -> some View {
    modifier(WelcomeFontModifier(role: role))
  }
}

// iOS type sizes from Apple's default text styles (Large Title 34, Body 17,
// Subheadline 15) in the token faces; the line heights come from the mock.
private enum WelcomeTypography {
  static let kaomoji = PutioFontRole(
    fontName: PutioTheme.Typography.title.fontName,
    size: 34,
    lineHeight: 1,
    textStyle: .largeTitle
  )
  static let title = PutioFontRole(
    fontName: PutioTheme.Components.Button.label.fontName,
    size: 34,
    // Apple's Large Title metric: 34/41.
    lineHeight: 41 / 34,
    textStyle: .largeTitle
  )
  static let lede = PutioFontRole(
    fontName: PutioTheme.Typography.body.fontName,
    size: 17,
    lineHeight: 1.4,
    textStyle: .body
  )
  static let notice = PutioFontRole(
    fontName: PutioTheme.Typography.body.fontName,
    size: 15,
    lineHeight: 1.3,
    textStyle: .subheadline
  )
  static let button = PutioFontRole(
    fontName: PutioTheme.Components.Button.label.fontName,
    size: 17,
    lineHeight: PutioTheme.Components.Button.label.lineHeight,
    textStyle: .body
  )
}

private enum WelcomeMetrics {
  static let headerHeight: CGFloat = 44
  static let wordmarkWidth: CGFloat = 88
  static let sideMargin: CGFloat = 20
  static let ledeMaxWidth: CGFloat = 296
  static let noticeRadius: CGFloat = 12
  static let kaomojiGap = PutioMetricRole(
    value: PutioTheme.Spacing.space4, relativeTo: .largeTitle)
  static let ledeGap = PutioMetricRole(value: PutioTheme.Spacing.space3, relativeTo: .body)
  static let detailGap = PutioMetricRole(value: PutioTheme.Spacing.space4, relativeTo: .body)
  static let noticeIcon = PutioMetricRole(value: 18, relativeTo: .subheadline)
}
