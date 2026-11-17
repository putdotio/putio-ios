import PutioCore
import SwiftUI

struct TrashLoadingView: View {
  let accessibilityLabel: String

  var body: some View {
    TrashRingSpinner()
      .accessibilityHidden(true)
      .overlay {
        Color.clear
          .accessibilityRepresentation {
            ProgressView()
              .accessibilityLabel(accessibilityLabel)
          }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct TrashRingSpinner: View {
  @PutioScaledMetric private var diameter: CGFloat
  @PutioScaledMetric private var lineWidth: CGFloat

  init() {
    _diameter = PutioScaledMetric(PutioMetricRole(value: 30, relativeTo: .body))
    _lineWidth = PutioScaledMetric(PutioMetricRole(value: 3, relativeTo: .body))
  }

  var body: some View {
    TimelineView(.animation) { context in
      ZStack {
        Circle()
          .stroke(PutioTheme.Colors.textPrimary.opacity(0.2), lineWidth: lineWidth)
        Circle()
          .trim(from: 0, to: 0.25)
          .stroke(PutioTheme.Colors.textPrimary, lineWidth: lineWidth)
          .rotationEffect(Self.angle(at: context.date))
      }
      .padding(lineWidth / 2)
      .frame(width: diameter, height: diameter)
    }
  }

  private static let period: TimeInterval = 0.8

  private static func angle(at date: Date) -> Angle {
    let turn = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    return .degrees(turn * 360 - 135)
  }
}

struct TrashErrorView: View {
  let title: String
  let message: String
  let retryTitle: String
  let retryIdentifier: String
  let retry: () -> Void

  var body: some View {
    ContentUnavailableView {
      VStack(spacing: PutioTheme.Spacing.space3) {
        Text(verbatim: PutioKaomoji.knockedOut.rawValue)
          .putioFont(Self.kaomojiFont)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityHidden(true)
        Text(title)
          .putioFont(PutioTheme.Typography.heading)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
      }
    } description: {
      Text(message)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
    } actions: {
      Button(action: retry) {
        Label {
          Text(retryTitle)
        } icon: {
          TrashRetryIcon()
        }
      }
      .buttonStyle(TrashRetryButtonStyle())
      .accessibilityIdentifier(retryIdentifier)
    }
  }

  private static let kaomojiFont = PutioFontRole(
    fontName: PutioTheme.Typography.mono.fontName,
    size: PutioTheme.Typography.sizeXl,
    lineHeight: PutioTheme.Typography.mono.lineHeight,
    textStyle: .title
  )
}

private struct TrashRetryIcon: View {
  @PutioScaledMetric private var size: CGFloat

  init() {
    _size = PutioScaledMetric(PutioMetricRole(value: 20, relativeTo: .body))
  }

  var body: some View {
    Image(putioIcon: .arrowCounterClockwise)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

private struct TrashRetryButtonStyle: ButtonStyle {
  @PutioScaledMetric private var height: CGFloat
  @PutioScaledMetric private var horizontalPadding: CGFloat
  @PutioScaledMetric private var gap: CGFloat

  init() {
    _height = PutioScaledMetric(PutioMetricRole(value: 44, relativeTo: .body))
    _horizontalPadding = PutioScaledMetric(PutioMetricRole(value: 22, relativeTo: .body))
    _gap = PutioScaledMetric(PutioTheme.ScaledMetrics.buttonContentGap)
  }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(TrashRetryLabelStyle(gap: gap))
      .putioFont(Self.labelFont)
      .foregroundStyle(PutioTheme.Colors.textPrimary)
      .padding(.horizontal, horizontalPadding)
      .frame(minHeight: height)
      .background(PutioTheme.Colors.surfaceActive, in: .capsule)
      .contentShape(.capsule)
      .opacity(configuration.isPressed ? 0.7 : 1)
  }

  private static let labelFont = PutioFontRole(
    fontName: PutioTheme.Components.Button.label.fontName,
    size: 17,
    lineHeight: PutioTheme.Components.Button.label.lineHeight,
    textStyle: .body
  )
}

private struct TrashRetryLabelStyle: LabelStyle {
  let gap: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: gap) {
      configuration.icon
      configuration.title
    }
  }
}
