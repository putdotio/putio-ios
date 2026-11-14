import PutioCore
import SwiftUI

struct PutioVideoConversionGate: View {
  enum Phase: Equatable {
    case waiting
    case converting(progress: Double)
  }

  let phase: Phase
  let onCancel: () -> Void
  let onOpenInVLC: (() -> Void)?

  var body: some View {
    ViewThatFits(in: .vertical) {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      ScrollView {
        content
          .frame(maxWidth: .infinity)
      }
    }
  }

  private var content: some View {
    VStack(spacing: PutioTheme.Spacing.space3) {
      VStack(spacing: PutioTheme.Spacing.space1) {
        Text(title)
          .putioFont(PutioTheme.Typography.subheading)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("video.conversion.title")
        Text(String(localized: "This video can’t play in its original format, so put.io started a conversion. It keeps going if you leave."))
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityIdentifier("conversion.explanation")
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      progress
        .padding(.top, PutioTheme.Spacing.space2)
      actions
        .padding(.top, PutioTheme.Spacing.space2)
    }
    .padding(.horizontal, PutioTheme.Spacing.space4)
    .padding(.vertical, PutioVideoConversionGateMetrics.verticalInset)
    .frame(maxWidth: PutioVideoConversionGateMetrics.maxWidth)
  }

  private var title: String {
    switch phase {
    case .waiting: String(localized: "Waiting to convert")
    case .converting: String(localized: "Converting to MP4")
    }
  }

  @ViewBuilder
  private var progress: some View {
    switch phase {
    case .waiting:
      PutioConversionWaitingBar()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Waiting to convert"))
        .accessibilityIdentifier("video.conversion-waiting")
    case .converting(let fraction):
      let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
      VStack(spacing: PutioTheme.Spacing.space2) {
        PutioConversionTrack(fraction: fraction)
        Text(percent)
          .putioFont(PutioVideoConversionGateMetrics.percentFont)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityHidden(true)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(String(localized: "Converting to MP4"))
      .accessibilityValue(percent)
      .accessibilityIdentifier("video.conversion-progress")
    }
  }

  private var actions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: PutioTheme.Spacing.space2) { actionButtons }
      VStack(spacing: PutioTheme.Spacing.space2) { actionButtons }
    }
  }

  @ViewBuilder
  private var actionButtons: some View {
    gateButton(String(localized: "Cancel"), identifier: "video.conversion.cancel", action: onCancel)
    if let onOpenInVLC {
      gateButton(
        String(localized: "Open in VLC"), identifier: "video.conversion.vlc", action: onOpenInVLC)
    }
  }

  private func gateButton(_ title: String, identifier: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Text(title)
        .putioFont(PutioTheme.Components.Button.label)
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.capsule)
    .controlSize(.regular)
    .tint(PutioTheme.Colors.textPrimary)
    .accessibilityIdentifier(identifier)
  }
}

private struct PutioConversionTrack: View {
  let fraction: Double

  var body: some View {
    Capsule()
      .fill(PutioVideoConversionGateMetrics.trackColor)
      .overlay(alignment: .leading) {
        GeometryReader { proxy in
          Capsule()
            .fill(PutioTheme.Colors.accent)
            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
        }
      }
      .frame(
        width: PutioVideoConversionGateMetrics.trackWidth,
        height: PutioVideoConversionGateMetrics.trackHeight)
  }
}

private struct PutioConversionWaitingBar: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { timeline in
      let width = PutioVideoConversionGateMetrics.trackWidth
      let segment = width * PutioVideoConversionGateMetrics.waitingSegment
      Capsule()
        .fill(PutioVideoConversionGateMetrics.trackColor)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(PutioTheme.Colors.accent)
            .frame(width: segment)
            .offset(x: offset(at: timeline.date, travel: width - segment))
        }
        .clipShape(Capsule())
        .frame(width: width, height: PutioVideoConversionGateMetrics.trackHeight)
    }
  }

  private func offset(at date: Date, travel: CGFloat) -> CGFloat {
    guard !reduceMotion else { return travel / 2 }
    let period = PutioVideoConversionGateMetrics.waitingPeriod
    let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    return travel * (1 - cos(phase * 2 * .pi)) / 2
  }
}

private enum PutioVideoConversionGateMetrics {
  static let maxWidth: CGFloat = 420
  static let trackWidth: CGFloat = 280
  static let trackHeight: CGFloat = 4
  static let waitingSegment: CGFloat = 1.0 / 3.0
  static let waitingPeriod: TimeInterval = 2
  static let verticalInset: CGFloat = 60
  static let trackColor = Color.white.opacity(0.15)
  static let percentFont = PutioFontRole(
    fontName: PutioTheme.Typography.mono.fontName,
    size: PutioTheme.Typography.sizeXs,
    lineHeight: PutioTheme.Typography.mono.lineHeight,
    textStyle: .caption2
  )
}
