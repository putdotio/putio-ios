import PutioCore
import SwiftUI

/// A failed playback with the recovery its failure allows.
struct TVPlaybackFailureScreen: View {
  let failure: PutioVideoPlaybackFailure
  let fileID: PutioFileID
  let fileName: String
  var reference: String?
  let retry: () -> Void
  let back: () -> Void

  var body: some View {
    let copy = TVPlaybackFailureCopy(failure)
    TVPlaybackStateScreen(
      fileName: fileName, kaomoji: copy.kaomoji, title: copy.title,
      message: copy.message(reference: reference)
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
    .accessibilityElement(children: .contain)
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
      message: Text("The stream stopped loading. Another proxy may be faster.", bundle: .putioCore)
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
            switch await proxy.select(name) {
            case .saved, .savedUnconfirmed: retry()
            default: break
            }
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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("video.stalled")
    .task { await preferences.loadSettingsIfNeeded() }
    .task { await proxy.loadIfNeeded() }
  }
}

/// A file put.io converts before it plays: the progress, Back while the
/// conversion keeps going, and Cancel conversion to stop it.
struct TVPlaybackConvertingScreen: View {
  let state: PutioVideoPlaybackState
  let fileName: String
  var cancelling = false
  let back: () -> Void
  let cancel: () -> Void

  @Environment(\.locale) private var locale

  var body: some View {
    let phase = state.conversionPhase ?? .waiting
    TVPlaybackStateScreen(
      fileName: fileName, kaomoji: nil, title: phase.title,
      message: Text(
        "Playback starts when it’s done. It keeps going if you leave.", bundle: .putioCore),
      messageIdentifier: "conversion.explanation"
    ) {
      progress(phase)
    } actions: {
      TVPlaybackStateButton(
        title: String(localized: "Back", bundle: .putioCore), icon: .arrowLeft,
        identifier: "video.conversion.back", action: back)
      TVPlaybackStateButton(
        title: String(localized: "Cancel conversion", bundle: .putioCore), icon: .x,
        identifier: "video.conversion.cancel", action: cancel
      )
      .disabled(cancelling)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }

  @ViewBuilder
  private func progress(_ phase: PutioVideoConversionPhase) -> some View {
    switch phase {
    case .converting(let progress):
      let percent = progress.formatted(.percent.precision(.fractionLength(0)).locale(locale))
      VStack(spacing: PutioTheme.TV.Spacing.small) {
        Capsule()
          .fill(.white.opacity(0.2))
          .frame(width: TVPlaybackStateLayout.progressWidth, height: TVPlaybackStateLayout.bar)
          .overlay(alignment: .leading) {
            Capsule()
              .fill(PutioTheme.Colors.accent)
              .frame(width: TVPlaybackStateLayout.progressWidth * min(max(progress, 0), 1))
          }
          .accessibilityElement()
          .accessibilityLabel(phase.title)
          .accessibilityValue(percent)
          .accessibilityIdentifier("video.conversion-progress")
        Text(verbatim: percent)
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
          .monospacedDigit()
          .accessibilityHidden(true)
      }
    case .waiting:
      ProgressView()
    }
  }

  private var identifier: String {
    switch state {
    case .conversionQueued: "video.conversion-queued"
    case .conversionRequired: "video.conversion-required"
    default: "video.converting"
    }
  }
}

private struct TVPlaybackFailureCopy {
  let identifier: String
  let kaomoji: String?
  let title: String
  let message: String
  let unexpected: Bool
  let offersRetry: Bool
  let retryTitle: String
  let showsWebCode: Bool

  init(_ failure: PutioVideoPlaybackFailure) {
    var retryTitle = PutioVideoPlaybackFailure.Recovery.tryAgainTitle
    var offersRetry = true
    var showsWebCode = false
    var unexpected = false
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
      unexpected = true
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
    self.unexpected = unexpected
  }

  func message(reference: String?) -> Text {
    guard unexpected, let reference, !reference.isEmpty else { return Text(message) }
    let id = Text(verbatim: reference).monospaced()
    return Text("Something unexpected happened. Error id \(id)", bundle: .putioCore)
  }
}

private struct TVPlaybackStateScreen<Extra: View, Actions: View>: View {
  let fileName: String
  let kaomoji: String?
  let title: String
  let message: Text
  var messageIdentifier = "video.failure.message"
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
        message
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier(messageIdentifier)
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
  static let progressWidth: CGFloat = 640
  static let bar: CGFloat = 10
}
