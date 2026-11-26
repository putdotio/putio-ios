import Foundation
import SwiftUI

#if !os(tvOS)
  public struct PutioDownloadStateButton: View {
    private let presentation: PutioDownloadPresentation
    private let fileName: String
    private let onAction: (PutioDownloadAction) -> Void

    @PutioScaledMetric(PutioDownloadStateLayout.target) private var target
    @PutioScaledMetric(PutioDownloadStateLayout.ring) private var ringSize
    @PutioScaledMetric(PutioDownloadStateLayout.ringStroke) private var ringStroke
    @PutioScaledMetric(PutioDownloadStateLayout.ringGlyph) private var ringGlyphSize
    @PutioScaledMetric(PutioDownloadStateLayout.stopGlyph) private var stopGlyphSize
    @PutioScaledMetric(PutioDownloadStateLayout.againGlyph) private var againGlyphSize

    init(
      presentation: PutioDownloadPresentation,
      fileName: String,
      onAction: @escaping (PutioDownloadAction) -> Void
    ) {
      self.presentation = presentation
      self.fileName = fileName
      self.onAction = onAction
    }

    public init(
      _ state: PutioDownloadState, fileName: String,
      onAction: @escaping (PutioDownloadAction) -> Void
    ) {
      self.init(
        presentation: PutioDownloadPresentation(state), fileName: fileName, onAction: onAction)
    }

    public var body: some View {
      if presentation.ring != .hidden, let action = presentation.action {
        Button {
          onAction(action)
        } label: {
          ring
            .frame(minWidth: target, minHeight: target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          Text(
            verbatim:
              "\(PutioDownloadPresentation.actionTitle(action)), \(fileName)"
          )
        )
        .accessibilityValue(accessibilityValue)
      }
    }

    @ViewBuilder private var ring: some View {
      switch presentation.ring {
      case .hidden:
        EmptyView()
      case .progress(let fraction, let isActive, let glyph):
        ZStack {
          Circle()
            .stroke(PutioTheme.Colors.separator, lineWidth: ringStroke)
          Circle()
            .trim(from: 0, to: fraction)
            .stroke(
              isActive ? PutioTheme.Colors.accent : PutioTheme.Colors.textSecondary,
              style: StrokeStyle(lineWidth: ringStroke, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
          glyphView(glyph)
        }
        .frame(width: ringSize, height: ringSize)
      case .dashed(let glyph):
        ZStack {
          Circle()
            .stroke(
              PutioTheme.Colors.textSecondary,
              style: StrokeStyle(
                lineWidth: ringStroke, lineCap: .round, dash: [ringStroke * 1.6, ringStroke * 1.6])
            )
          if let glyph {
            glyphView(glyph)
          }
        }
        .frame(width: ringSize, height: ringSize)
      case .glyph(let glyph):
        glyphView(glyph)
      }
    }

    private func glyphView(_ glyph: PutioDownloadPresentation.Glyph) -> some View {
      let (icon, size, color): (PutioIcon, CGFloat, Color) =
        switch glyph {
        case .pause: (.pauseFill, ringGlyphSize, PutioTheme.Colors.textPrimary)
        case .play: (.playFill, ringGlyphSize, PutioTheme.Colors.textPrimary)
        case .stop: (.stopFill, stopGlyphSize, PutioTheme.Colors.textSecondary)
        case .again: (.arrowCounterClockwise, againGlyphSize, PutioTheme.Colors.textSecondary)
        case .download: (.arrowCircleDown, againGlyphSize, PutioTheme.Colors.textSecondary)
        }
      return Image(putioIcon: icon)
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)
        .foregroundStyle(color)
    }

    private var accessibilityValue: Text {
      guard let progress = presentation.progress else { return Text(verbatim: "") }
      return Text(progress, format: .percent.precision(.fractionLength(0)))
    }
  }

  enum PutioDownloadStateLayout {
    static let target = PutioMetricRole(value: 44, relativeTo: .body)
    static let ring = PutioMetricRole(value: 26, relativeTo: .body)
    static let ringStroke = PutioMetricRole(value: 2.5, relativeTo: .body)
    static let ringGlyph = PutioMetricRole(value: 11, relativeTo: .body)
    static let stopGlyph = PutioMetricRole(value: 9, relativeTo: .body)
    static let againGlyph = PutioMetricRole(value: 24, relativeTo: .body)
  }
#endif
