import PutioCore
import SwiftUI

/// A failed playback with the recovery its failure allows.
struct TVPlaybackFailureScreen: View {
  let failure: PutioVideoPlaybackFailure
  let fileID: PutioFileID
  let fileName: String
  let retry: () -> Void
  let back: () -> Void

  var body: some View {
    let copy = TVPlaybackFailureCopy(failure)
    TVPlaybackStateScreen(
      fileName: fileName, kaomoji: copy.kaomoji, title: copy.title, message: copy.message
    ) {
      if copy.showsWebCode {
        PutioQRCodeView(PutioWebLinks.file(fileID).absoluteString, size: TVPlaybackStateLayout.qr)
          .accessibilityElement()
          .accessibilityLabel(
            Text("QR code that opens this file on the web", bundle: .putioCore)
          )
          .accessibilityIdentifier("video.web-code")
      }
    } actions: {
      if copy.offersRetry {
        TVPlaybackStateButton(
          title: copy.retryTitle, icon: .arrowsClockwise, identifier: "video.retry",
          action: retry)
      }
      TVPlaybackStateButton(
        title: String(localized: "Back", bundle: .putioCore), icon: .arrowLeft,
        identifier: "video.back", action: back)
    }
    .accessibilityIdentifier("video.failure.\(copy.identifier)")
  }
}

/// The stream stopped loading: try again, pick another proxy, or leave.
struct TVPlaybackStalledScreen: View {
  let fileName: String
  let retry: () -> Void
  let back: () -> Void

  @State private var preferences: PutioAccountPreferencesModel
  @State private var proxy: PutioProxyChooserModel

  init(
    fileName: String, runtime: PutioRuntime, retry: @escaping () -> Void, back: @escaping () -> Void
  ) {
    self.fileName = fileName
    self.retry = retry
    self.back = back
    let preferences = PutioAccountPreferencesModel(actions: .init(runtime: runtime))
    _preferences = State(initialValue: preferences)
    _proxy = State(
      initialValue: PutioProxyChooserModel(
        actions: PutioProxyChooserActions(runtime: runtime), preferences: preferences))
  }

  var body: some View {
    TVPlaybackStateScreen(
      fileName: fileName, kaomoji: "(・_・;)", title: PutioVideoWait.stalledTitle,
      message: String(
        localized: "The stream stopped loading. Another proxy may be faster.", bundle: .putioCore)
    ) {
      EmptyView()
    } actions: {
      TVPlaybackStateButton(
        title: PutioVideoPlaybackFailure.Recovery.tryAgainTitle, icon: .arrowsClockwise,
        identifier: "video.stalled.retry", action: retry)
      TVProxyMenu(
        state: TVProxyMenuState(model: proxy),
        select: { name in
          Task {
            if case .saved = await proxy.select(name) { retry() }
          }
        },
        retry: { Task { await proxy.loadRoutes() } }
      ) {
        TVPlaybackStateLabel(
          title: String(localized: "Choose your proxy", bundle: .putioCore), icon: .globe)
      }
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .fixedSize()
      .accessibilityIdentifier("video.stalled.proxy")
      TVPlaybackStateButton(
        title: String(localized: "Back", bundle: .putioCore), icon: .arrowLeft,
        identifier: "video.stalled.back", action: back)
    }
    .accessibilityIdentifier("video.stalled")
    .task { await preferences.loadSettingsIfNeeded() }
    .task { await proxy.loadIfNeeded() }
  }
}

private struct TVPlaybackFailureCopy {
  let identifier: String
  let kaomoji: String?
  let title: String
  let message: String
  let offersRetry: Bool
  let retryTitle: String
  let showsWebCode: Bool

  init(_ failure: PutioVideoPlaybackFailure) {
    var retryTitle = PutioVideoPlaybackFailure.Recovery.tryAgainTitle
    var offersRetry = true
    var showsWebCode = false
    switch failure.kind {
    case .connectionLost:
      identifier = "connection-lost"
      kaomoji = "(x_x)"
      title = String(localized: "Connection lost", bundle: .putioCore)
      message = String(
        localized: "Check your internet connection and try again.", bundle: .putioCore)
    case .accessExpired:
      identifier = "link-expired"
      kaomoji = "(._.)"
      title = String(localized: "Playback link expired", bundle: .putioCore)
      message = String(localized: "Go back and try again.", bundle: .putioCore)
      offersRetry = false
    case .unsupported, .conversionUnavailable:
      identifier = "unsupported"
      kaomoji = nil
      title = failure.title
      message = String(
        localized: "This format doesn’t play on Apple TV. Scan to play it on the web.",
        bundle: .putioCore)
      offersRetry = false
      showsWebCode = true
    case .playback, .invalidResponse, .unknown:
      identifier = "error"
      kaomoji = "(⊙_⊙)"
      title = String(localized: "Playback error", bundle: .putioCore)
      message = String(localized: "Something unexpected happened.", bundle: .putioCore)
    case .conversion:
      identifier = "conversion"
      kaomoji = "(⊙_⊙)"
      title = failure.title
      message = failure.message
      retryTitle = PutioVideoPlaybackFailure.Recovery.convertAgainTitle
    case .notFound, .rateLimited, .transient, .conversionStatus:
      identifier = "error"
      kaomoji = "(⊙_⊙)"
      title = failure.title
      message = failure.message
    }
    self.offersRetry = offersRetry
    self.retryTitle = retryTitle
    self.showsWebCode = showsWebCode
  }
}

private struct TVPlaybackStateScreen<Extra: View, Actions: View>: View {
  let fileName: String
  let kaomoji: String?
  let title: String
  let message: String
  @ViewBuilder let extra: Extra
  @ViewBuilder let actions: Actions

  var body: some View {
    ZStack(alignment: .topLeading) {
      VStack(spacing: PutioTheme.TV.Spacing.small) {
        if let kaomoji {
          Text(verbatim: kaomoji)
            .putioFont(PutioTheme.TV.Typography.heading)
            .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
            .accessibilityHidden(true)
        }
        Text(title)
          .putioFont(PutioTheme.TV.Typography.label)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("video.failure.title")
        Text(message)
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("video.failure.message")
        extra
          .padding(.top, PutioTheme.TV.Spacing.small)
        HStack(spacing: PutioTheme.TV.Spacing.small) {
          actions
        }
        .padding(.top, PutioTheme.TV.Spacing.medium)
        .focusSection()
      }
      .frame(maxWidth: TVPlaybackStateLayout.width)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Text(fileName)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .lineLimit(1)
        .accessibilityIdentifier("video.failure.file-name")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tvOverscanPadding()
    }
    .background(TVResumePromptLayout.backdrop.ignoresSafeArea())
  }
}

private struct TVPlaybackStateButton: View {
  let title: String
  let icon: PutioIcon
  let identifier: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      TVPlaybackStateLabel(title: title, icon: icon)
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.capsule)
    .fixedSize()
    .accessibilityIdentifier(identifier)
  }
}

private struct TVPlaybackStateLabel: View {
  let title: String
  let icon: PutioIcon

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.xs) {
      Image(putioIcon: icon)
        .resizable()
        .scaledToFit()
        .frame(width: TVPlaybackStateLayout.glyph, height: TVPlaybackStateLayout.glyph)
        .accessibilityHidden(true)
      Text(title)
    }
    .putioFont(PutioButtonSize.regular.brandLabel)
  }
}

enum TVPlaybackStateLayout {
  static let width: CGFloat = 1200
  static let qr: CGFloat = 300
  static let glyph: CGFloat = 32
}
