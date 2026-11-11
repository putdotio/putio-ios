import Foundation
import SwiftUI

public enum PutioDownloadWait: Equatable, Sendable {
  case network
  case storage
}

public enum PutioDownloadState: Equatable, Sendable {
  case idle
  case downloading(receivedBytes: Int64, totalBytes: Int64)
  case converting(progress: Double)
  case paused(receivedBytes: Int64, totalBytes: Int64)
  case waiting(PutioDownloadWait, receivedBytes: Int64, totalBytes: Int64)
  case queued(position: Int)
  case removing
  case missing
  case failed(reason: String)
}

public enum PutioDownloadAction: Equatable, Sendable {
  case pause
  case resume
  case cancel
  case retry
  case downloadAgain
}

public struct PutioDownloadPresentation: Equatable, Sendable {
  public enum Glyph: Equatable, Sendable {
    case pause
    case play
    case stop
    case again
  }

  public enum Ring: Equatable, Sendable {
    case hidden
    case progress(Double, isActive: Bool, glyph: Glyph)
    case dashed(glyph: Glyph?)
    case glyph(Glyph)
  }

  public enum Tone: Equatable, Sendable {
    case secondary
    case destructive
  }

  public struct Segment: Equatable, Sendable {
    public let text: String
    public let isNumeric: Bool

    init(_ text: String, isNumeric: Bool = false) {
      self.text = text
      self.isNumeric = isNumeric
    }
  }

  public let statusLine: [Segment]
  public let tone: Tone
  public let ring: Ring
  public let action: PutioDownloadAction?
  public let progress: Double?
  public let dimsRow: Bool

  public init(_ state: PutioDownloadState, locale: Locale = .current) {
    var statusLine: [Segment] = []
    var tone = Tone.secondary
    var ring = Ring.hidden
    var action: PutioDownloadAction?
    var progress: Double?
    var dimsRow = false

    switch state {
    case .idle:
      break
    case .downloading(let received, let total):
      let fraction = Self.fraction(received, of: total)
      statusLine = [
        Segment(Self.bytesText(received, of: total, locale: locale), isNumeric: true),
        Segment(Self.percentText(fraction, locale: locale), isNumeric: true),
      ]
      ring = .progress(fraction, isActive: true, glyph: .pause)
      action = .pause
      progress = fraction
    case .converting(let value):
      let fraction = min(max(value, 0), 1)
      statusLine = [
        Segment(String(localized: "Converting", bundle: .module, locale: locale)),
        Segment(Self.percentText(fraction, locale: locale), isNumeric: true),
      ]
      ring = .progress(fraction, isActive: true, glyph: .pause)
      action = .pause
      progress = fraction
    case .paused(let received, let total):
      let fraction = Self.fraction(received, of: total)
      statusLine = [
        Segment(String(localized: "Paused", bundle: .module, locale: locale)),
        Segment(Self.bytesText(received, of: total, locale: locale), isNumeric: true),
      ]
      ring = .progress(fraction, isActive: false, glyph: .play)
      action = .resume
      progress = fraction
    case .waiting(let wait, let received, let total):
      let reason = Self.waitText(wait, locale: locale)
      if received > 0 {
        let fraction = Self.fraction(received, of: total)
        statusLine = [
          Segment(reason),
          Segment(Self.bytesText(received, of: total, locale: locale), isNumeric: true),
        ]
        ring = .progress(fraction, isActive: false, glyph: .pause)
        action = .pause
        progress = fraction
      } else {
        statusLine = [Segment(reason)]
        ring = .dashed(glyph: nil)
        action = .cancel
      }
    case .queued(let position):
      statusLine = [
        Segment(String(localized: "Queued · #\(position) in line", bundle: .module, locale: locale))
      ]
      ring = .dashed(glyph: .stop)
      action = .cancel
    case .removing:
      statusLine = [
        Segment(String(localized: "Removing from this iPhone…", bundle: .module, locale: locale))
      ]
      dimsRow = true
    case .missing:
      statusLine = [
        Segment(String(localized: "No longer on this iPhone", bundle: .module, locale: locale))
      ]
      tone = .destructive
      ring = .glyph(.again)
      action = .downloadAgain
    case .failed(let reason):
      statusLine = [Segment(reason)]
      tone = .destructive
      ring = .glyph(.again)
      action = .retry
    }

    self.statusLine = statusLine
    self.tone = tone
    self.ring = ring
    self.action = action
    self.progress = progress
    self.dimsRow = dimsRow
  }

  public static func actionTitle(_ action: PutioDownloadAction, locale: Locale = .current)
    -> String
  {
    switch action {
    case .pause: String(localized: "Pause download", bundle: .module, locale: locale)
    case .resume: String(localized: "Resume download", bundle: .module, locale: locale)
    case .cancel: String(localized: "Cancel download", bundle: .module, locale: locale)
    case .retry: String(localized: "Retry download", bundle: .module, locale: locale)
    case .downloadAgain: String(localized: "Download again", bundle: .module, locale: locale)
    }
  }

  static func bytesText(_ received: Int64, of total: Int64, locale: Locale) -> String {
    guard total > 0 else {
      return PutioFileRowModel.sizeText(bytes: received, locale: locale)
    }
    let unit = ByteUnit(total)
    let totalText = total.formatted(
      ByteCountFormatStyle(style: .file, allowedUnits: unit.allowedUnits, locale: locale))
    let receivedText = (Double(max(received, 0)) / unit.divisor).formatted(
      .number.precision(.fractionLength(0...unit.fractionDigits)).locale(locale))
    return String(localized: "\(receivedText) of \(totalText)", bundle: .module, locale: locale)
  }

  private static func fraction(_ received: Int64, of total: Int64) -> Double {
    guard total > 0 else { return 0 }
    return min(max(Double(received) / Double(total), 0), 1)
  }

  private static func percentText(_ fraction: Double, locale: Locale) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
  }

  private static func waitText(_ wait: PutioDownloadWait, locale: Locale) -> String {
    switch wait {
    case .network: String(localized: "Waiting for network", bundle: .module, locale: locale)
    case .storage: String(localized: "Waiting for storage", bundle: .module, locale: locale)
    }
  }

  private struct ByteUnit {
    let allowedUnits: ByteCountFormatStyle.Units
    let divisor: Double
    let fractionDigits: Int

    init(_ total: Int64) {
      switch total {
      case ..<1_000:
        self.init(.bytes, power: 0, fractionDigits: 0)
      case ..<1_000_000:
        self.init(.kb, power: 1, fractionDigits: 0)
      case ..<1_000_000_000:
        self.init(.mb, power: 2, fractionDigits: 1)
      case ..<1_000_000_000_000:
        self.init(.gb, power: 3, fractionDigits: 2)
      default:
        self.init(.tb, power: 4, fractionDigits: 2)
      }
    }

    private init(_ units: ByteCountFormatStyle.Units, power: Int, fractionDigits: Int) {
      allowedUnits = units
      divisor = pow(1_000, Double(power))
      self.fractionDigits = fractionDigits
    }
  }
}

#if !os(tvOS)
  struct PutioDownloadStateButton: View {
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

    var body: some View {
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
