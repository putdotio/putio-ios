import AuthenticationServices
import PutioCore
import SwiftUI

struct WelcomeScreen: View {
  enum Mode: Equatable {
    case fresh
    case sessionExpired
    case signInFailed
    case restoreFailed(PutioRestoreFailureCause)
  }

  enum DeviceNoun: Equatable {
    case iPhone
    case iPad

    @MainActor static var current: DeviceNoun {
      UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
    }
  }

  let mode: Mode
  var isCheckingSession = false
  var deviceNoun: DeviceNoun = .iPhone
  var pinnedFrame: Int?
  var exposesStageProbe = false
  var signIn: () -> Void = {}
  var retryRestore: () -> Void = {}
  var discardCredential: () -> Void = {}

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @PutioScaledMetric(WelcomeMetrics.titleGap) private var titleGap
  @PutioScaledMetric(WelcomeMetrics.ledeGap) private var ledeGap

  var body: some View {
    GeometryReader { outer in
      content(hasBottomInset: outer.safeAreaInsets.bottom > 0)
    }
  }

  private func content(hasBottomInset: Bool) -> some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          Spacer(minLength: WelcomeMetrics.stageMinimumGap)
          WelcomeStage(
            frames: frames,
            pinnedFrame: pinnedFrame,
            exposesProbe: exposesStageProbe,
            kaomojiSize: isRegular ? WelcomeMetrics.regularKaomoji : WelcomeMetrics.compactKaomoji
          )
          Spacer(minLength: WelcomeMetrics.stageMinimumGap)
          copy
        }
        .padding(.horizontal, WelcomeMetrics.sideMargin)
        .padding(.bottom, PutioTheme.Spacing.space2)
        .frame(maxWidth: columnWidth)
        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .safeAreaInset(edge: .top, spacing: 0) { header }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      actions(bottomPadding: isRegular || !hasBottomInset ? PutioTheme.Spacing.space3 : 0)
    }
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }

  private var isRegular: Bool { horizontalSizeClass == .regular }

  private var columnWidth: CGFloat? {
    isRegular ? WelcomeMetrics.regularColumnWidth + 2 * WelcomeMetrics.sideMargin : nil
  }

  private var textAlignment: TextAlignment { isRegular ? .center : .leading }

  private var frameAlignment: Alignment { isRegular ? .center : .leading }

  private var header: some View { WelcomeWordmark() }

  private var copy: some View {
    VStack(spacing: 0) {
      if let notice {
        notice
          .padding(.bottom, titleGap)
      }
      Text(title)
        .putioFont(WelcomeTypography.title)
        .tracking(WelcomeTypography.title.size * -0.02)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("auth.welcome-title")
      Text(lede)
        .putioFont(WelcomeTypography.lede)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .padding(.top, ledeGap)
        .accessibilityIdentifier("auth.welcome-lede")
    }
    .multilineTextAlignment(textAlignment)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var notice: WelcomeNotice? {
    switch mode {
    case .fresh, .sessionExpired:
      nil
    case .signInFailed:
      WelcomeNotice(
        title: String(localized: "Sign-in didn’t finish"),
        message: String(localized: "Nothing was saved, so you can try again.")
      )
    case .restoreFailed(.sessionCheck):
      WelcomeNotice(
        title: String(localized: "Couldn’t check your session"),
        message: String(
          localized: "Your sign-in is still saved. Check your connection and try again.")
      )
    case .restoreFailed(.secureStorage):
      WelcomeNotice(
        title: String(localized: "Secure storage is unavailable"),
        message: secureStorageMessage
      )
    }
  }

  private var secureStorageMessage: String {
    switch deviceNoun {
    case .iPhone:
      String(
        localized:
          "Your session couldn’t be read or saved safely on this iPhone. Reset clears it so you can sign in again."
      )
    case .iPad:
      String(
        localized:
          "Your session couldn’t be read or saved safely on this iPad. Reset clears it so you can sign in again."
      )
    }
  }

  private func actions(bottomPadding: CGFloat) -> some View {
    VStack(spacing: PutioTheme.Spacing.space2) {
      switch mode {
      case .fresh, .sessionExpired, .signInFailed:
        WelcomeButton(
          primaryTitle,
          prominent: true,
          busyTitle: isCheckingSession ? String(localized: "Checking your session") : nil,
          action: signIn
        )
        .accessibilityIdentifier("auth.sign-in")
      case .restoreFailed(let cause):
        WelcomeButton(String(localized: "Try again"), prominent: true, action: retryRestore)
          .accessibilityIdentifier("auth.retry")
        WelcomeButton(discardTitle(cause), prominent: false, action: discardCredential)
          .accessibilityIdentifier("auth.discard-credential")
      }
    }
    .padding(.horizontal, WelcomeMetrics.sideMargin)
    .frame(maxWidth: columnWidth)
    .padding(.top, PutioTheme.Spacing.space3)
    .padding(.bottom, bottomPadding)
    .frame(maxWidth: .infinity)
    .background(PutioTheme.Colors.background)
  }

  private func discardTitle(_ cause: PutioRestoreFailureCause) -> String {
    switch cause {
    case .sessionCheck: String(localized: "Sign in again")
    case .secureStorage: String(localized: "Reset and sign in")
    }
  }

  private var primaryTitle: String {
    mode == .signInFailed ? String(localized: "Try again") : String(localized: "Sign in")
  }

  private var frames: [WelcomeFrame] {
    switch mode {
    case .fresh, .sessionExpired: WelcomeFrame.sequence
    case .signInFailed, .restoreFailed: [WelcomeFrame.failed]
    }
  }

  private var title: String {
    switch mode {
    case .fresh, .signInFailed, .restoreFailed: String(localized: "Welcome!")
    case .sessionExpired: String(localized: "Welcome back!")
    }
  }

  private var lede: String {
    switch mode {
    case .sessionExpired:
      String(localized: "Your session expired. Sign in again to continue.")
    case .fresh, .signInFailed, .restoreFailed:
      switch deviceNoun {
      case .iPhone: String(localized: "Your put.io files, streaming and offline on this iPhone.")
      case .iPad: String(localized: "Your put.io files, streaming and offline on this iPad.")
      }
    }
  }
}

extension WelcomeScreen.Mode {
  init(reason: PutioSignedOutReason?) {
    switch reason {
    case nil, .userSignedOut: self = .fresh
    case .sessionExpired: self = .sessionExpired
    case .authenticationFailed: self = .signInFailed
    case .restoreFailed(let cause, _): self = .restoreFailed(cause)
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
  @State private var isBrowserOpen = false
  @State private var isRetryingRestore = false

  var body: some View {
    if isRetryingRestore {
      SessionProgressScreen(title: String(localized: "Restoring your session"))
    } else {
      welcome
    }
  }

  private var welcome: some View {
    WelcomeScreen(
      mode: mode,
      isCheckingSession: session.state == .authenticating && !isBrowserOpen,
      deviceNoun: .current,
      pinnedFrame: pinnedFrame,
      exposesStageProbe: exposesStageProbe,
      signIn: { Task { await startSignIn() } },
      retryRestore: { Task { await retryRestore() } },
      discardCredential: discardCredential
    )
    .onChange(of: session.state, initial: true) { _, state in
      if case .signedOut(let reason) = state { lastMode = WelcomeScreen.Mode(reason: reason) }
    }
  }

  private var mode: WelcomeScreen.Mode {
    if case .signedOut(let reason) = session.state { return WelcomeScreen.Mode(reason: reason) }
    return lastMode
  }

  private var pinnedFrame: Int? {
    #if DEBUG
      HarnessSignIn.pinnedWelcomeFrame
    #else
      nil
    #endif
  }

  private var exposesStageProbe: Bool {
    #if DEBUG
      HarnessSignIn.exposesWelcomeStage
    #else
      false
    #endif
  }

  private func retryRestore() async {
    guard !isRetryingRestore else { return }
    isRetryingRestore = true
    defer { isRetryingRestore = false }
    await session.restore()
  }

  private func discardCredential() {
    session.discardUnrestoredCredential()
    guard case .signedOut(nil) = session.state else { return }
    Task { await startSignIn() }
  }

  private func startSignIn() async {
    lastMode = mode == .sessionExpired ? .sessionExpired : .fresh
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
          await HarnessSignIn.complete(request, session: session)
          return
        }
      #endif
      isBrowserOpen = true
      let callbackURL: URL
      do {
        defer { isBrowserOpen = false }
        callbackURL = try await webAuthenticationSession.authenticate(
          using: request.url,
          callbackURLScheme: request.callbackScheme
        )
      }
      await session.completeSignIn(callbackURL: callbackURL)
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      session.cancelSignIn()
    } catch {
      session.failSignIn(error)
    }
  }
}

struct SessionProgressScreen: View {
  let title: String

  var body: some View {
    PutioLoadingStateView(title: title)
      .overlay(alignment: .top) { WelcomeWordmark() }
      .background(PutioTheme.Colors.background.ignoresSafeArea())
  }
}

private struct WelcomeWordmark: View {
  var body: some View {
    Image.putioWordmark
      .resizable()
      .scaledToFit()
      .frame(width: WelcomeMetrics.wordmarkWidth)
      .frame(maxWidth: .infinity)
      .frame(height: WelcomeMetrics.headerHeight)
      .accessibilityLabel("put.io")
      .accessibilityRemoveTraits(.isImage)
  }
}

struct WelcomeFrame: Equatable {
  let kaomoji: String
  let caption: String

  static let sequence = [
    WelcomeFrame(kaomoji: "ᕕ( ᐛ )ᕗ", caption: String(localized: "Stream it anywhere.")),
    WelcomeFrame(kaomoji: "(づ｡◕‿‿◕｡)づ", caption: String(localized: "Or keep it offline.")),
  ]

  static let failed = WelcomeFrame(
    kaomoji: "(・_・;)", caption: String(localized: "That didn’t work."))
}

private struct WelcomeStage: View {
  let frames: [WelcomeFrame]
  let pinnedFrame: Int?
  let exposesProbe: Bool
  let kaomojiSize: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var start = Date.now

  var body: some View {
    TimelineView(.animation(paused: !rolls)) { context in
      let position = sequencePosition(at: context.date)
      ZStack {
        VStack(spacing: WelcomeMetrics.dotsGap) {
          strip(position: position)
          if frames.count > 1 {
            WelcomeDots(count: frames.count, position: position)
          }
        }
        .accessibilityHidden(true)
        #if DEBUG
          if exposesProbe {
            HarnessWelcomeStageProbe(
              frame: Int(position.rounded()) % frames.count,
              rolls: rolls,
              showsDots: frames.count > 1
            )
          }
        #endif
      }
    }
    .frame(maxWidth: .infinity)
    .onChange(of: rolls) { _, rolls in
      if rolls { start = .now }
    }
  }

  private var rolls: Bool {
    frames.count > 1 && !reduceMotion && pinnedFrame == nil
  }

  private func sequencePosition(at date: Date) -> Double {
    guard rolls else {
      return Double(min(max(pinnedFrame ?? 0, 0), frames.count - 1))
    }
    return PutioWelcomeSequence.position(
      elapsed: date.timeIntervalSince(start), frameCount: frames.count)
  }

  private func strip(position: Double) -> some View {
    let strip = frames.count > 1 ? frames + [frames[0]] : frames
    return ZStack {
      ForEach(frames.indices, id: \.self) { index in
        WelcomeFrameView(frame: frames[index], kaomojiSize: kaomojiSize).hidden()
      }
    }
    .frame(minHeight: WelcomeMetrics.minimumFrameHeight)
    .overlay {
      GeometryReader { proxy in
        let frameHeight = proxy.size.height
        VStack(spacing: 0) {
          ForEach(strip.indices, id: \.self) { index in
            WelcomeFrameView(frame: strip[index], kaomojiSize: kaomojiSize)
              .frame(height: frameHeight)
          }
        }
        .offset(y: -position * frameHeight)
        .frame(height: frameHeight, alignment: .top)
      }
    }
    .clipped()
  }
}

private struct WelcomeFrameView: View {
  let frame: WelcomeFrame
  let kaomojiSize: CGFloat

  var body: some View {
    VStack(spacing: WelcomeMetrics.captionGap) {
      Text(verbatim: frame.kaomoji)
        .putioFont(WelcomeTypography.kaomoji(size: kaomojiSize))
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
      Text(frame.caption)
        .putioFont(WelcomeTypography.caption)
        .foregroundStyle(PutioTheme.Colors.accent)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
    .padding(.horizontal, WelcomeMetrics.sideMargin)
    .frame(maxWidth: .infinity)
  }
}

private struct WelcomeDots: View {
  let count: Int
  let position: Double

  var body: some View {
    HStack(spacing: WelcomeMetrics.dotSpacing) {
      ForEach(0..<count, id: \.self) { index in
        let weight = currentness(of: index)
        Capsule()
          .fill(PutioTheme.Colors.textPrimary.opacity(weight))
          .background(PutioTheme.Colors.borderActive, in: .capsule)
          .frame(
            width: WelcomeMetrics.dot + (WelcomeMetrics.activeDot - WelcomeMetrics.dot) * weight,
            height: WelcomeMetrics.dot
          )
      }
    }
  }

  private func currentness(of index: Int) -> Double {
    let distance = min(
      abs(position - Double(index)), abs(position - Double(index) - Double(count)))
    return min(max(1 - distance, 0), 1)
  }
}

private struct WelcomeNotice: View {
  let title: String
  let message: String

  @ScaledMetric(relativeTo: .subheadline) private var textSize = WelcomeTypography.notice.size

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: WelcomeMetrics.noticeIconGap) {
      PutioIconView(.warningCircleFill, size: WelcomeMetrics.noticeIcon)
        .foregroundStyle(PutioTheme.Colors.destructive)
        .alignmentGuide(.firstTextBaseline) { dimensions in
          dimensions[VerticalAlignment.center] + capHeight / 2
        }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WelcomeMetrics.noticeLineGap) {
        Text(title)
          .putioFont(WelcomeTypography.noticeTitle)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
        Text(message)
          .putioFont(WelcomeTypography.notice)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, WelcomeMetrics.noticeVerticalPadding)
    .padding(.horizontal, PutioTheme.Spacing.space3)
    .background(PutioTheme.Colors.surface, in: .rect(cornerRadius: WelcomeMetrics.noticeRadius))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("auth.notice")
  }

  private var capHeight: CGFloat {
    let font =
      UIFont(name: WelcomeTypography.noticeTitle.fontName, size: textSize)
      ?? .systemFont(ofSize: textSize)
    return font.capHeight
  }
}

private struct WelcomeButton: View {
  let title: String
  let prominent: Bool
  let busyTitle: String?
  let action: () -> Void

  init(
    _ title: String, prominent: Bool, busyTitle: String? = nil, action: @escaping () -> Void
  ) {
    self.title = title
    self.prominent = prominent
    self.busyTitle = busyTitle
    self.action = action
  }

  var body: some View {
    if let busyTitle {
      Button(action: {}) {
        HStack(spacing: PutioTheme.Spacing.space2) {
          ProgressView()
            .controlSize(.regular)
            .tint(PutioTheme.Colors.textSecondary)
          Text(busyTitle)
        }
        .putioFont(WelcomeTypography.button)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .modifier(WelcomeButtonShape())
      .tint(PutioTheme.Colors.textSecondary)
      .disabled(true)
      .accessibilityLabel(busyTitle)
    } else if prominent {
      Button(action: action) {
        label.foregroundStyle(PutioTheme.Components.Button.primaryForeground)
      }
      .buttonStyle(.borderedProminent)
      .modifier(WelcomeButtonShape())
    } else {
      Button(action: action) {
        label.foregroundStyle(PutioTheme.Components.Button.secondaryForeground)
      }
      .buttonStyle(.borderedProminent)
      .modifier(WelcomeButtonShape())
      .tint(PutioTheme.Components.Button.secondaryBackground)
    }
  }

  private var label: some View {
    Text(title)
      .putioFont(WelcomeTypography.button)
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

// iOS type sizes from Apple's default text styles (Large Title 34, Body 17,
// Subheadline 15) in the token faces; the line heights come from the mock.
private enum WelcomeTypography {
  static func kaomoji(size: CGFloat) -> PutioFontRole {
    PutioFontRole(
      fontName: PutioTheme.Components.Button.label.fontName,
      size: size,
      lineHeight: 1.15,
      textStyle: .largeTitle
    )
  }
  static let caption = PutioFontRole(
    fontName: PutioTheme.Typography.mono.fontName,
    size: 15,
    lineHeight: 20 / 15,
    textStyle: .subheadline
  )
  static let title = PutioFontRole(
    fontName: PutioTheme.Components.Button.label.fontName,
    size: 34,
    lineHeight: 41 / 34,
    textStyle: .largeTitle
  )
  static let lede = PutioFontRole(
    fontName: PutioTheme.Typography.body.fontName,
    size: 17,
    lineHeight: 1.4,
    textStyle: .body
  )
  static let noticeTitle = PutioFontRole(
    fontName: PutioTheme.Components.Button.label.fontName,
    size: 15,
    lineHeight: 1.3,
    textStyle: .subheadline
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
  static let regularColumnWidth: CGFloat = 440
  static let stageMinimumGap = PutioTheme.Spacing.space3
  static let compactKaomoji = PutioTheme.Typography.size2xl
  static let regularKaomoji = PutioTheme.Typography.size3xl
  static let minimumFrameHeight: CGFloat = 152
  static let captionGap = PutioTheme.Spacing.space3
  static let dotsGap = PutioTheme.Spacing.space2
  static let dot: CGFloat = 6
  static let activeDot: CGFloat = 18
  static let dotSpacing = PutioTheme.Spacing.space2
  static let noticeRadius: CGFloat = 12
  static let noticeVerticalPadding: CGFloat = 14
  static let noticeIconGap: CGFloat = 12
  static let noticeLineGap: CGFloat = 2
  static let titleGap = PutioMetricRole(
    value: PutioTheme.Spacing.space3 + PutioTheme.Spacing.space2, relativeTo: .largeTitle)
  static let ledeGap = PutioMetricRole(value: PutioTheme.Spacing.space2, relativeTo: .body)
  static let noticeIcon = PutioMetricRole(value: 18, relativeTo: .subheadline)
}
