import SwiftUI

public enum PutioDownloadState: Equatable, Sendable {
  case idle
  case queued
  case downloading(progress: Double)
  case downloaded
  case failed
}

#if os(iOS) || os(watchOS)
  // The one composed control on this tier (ios-e16, ios-s02): iOS has no
  // determinate circular progress button, so the app pairs a stock
  // Gauge(.accessoryCircularCapacity) with an SF Symbol in a 44pt target.
  // Five states, one position. The glyph swaps by state, never the ring.
  // A queue is not progress, so queued shows no ring; failed reuses the idle
  // glyph and leaves the reason to the row subtitle.
  //
  // Known gap, recorded upstream: the contract wants the ring track on
  // `--line`, but the stock gauge style derives its track from the tint and
  // exposes no track color. The stock ring wins over a drawn one.
  public struct PutioDownloadStateButton: View {
    private let state: PutioDownloadState
    private let action: () -> Void

    @PutioScaledMetric(PutioDownloadStateLayout.target) private var target
    @PutioScaledMetric(PutioDownloadStateLayout.actionGlyph) private var actionGlyphSize
    @PutioScaledMetric(PutioDownloadStateLayout.stopGlyph) private var stopGlyphSize
    @PutioScaledMetric(PutioDownloadStateLayout.doneGlyph) private var doneGlyphSize

    public init(state: PutioDownloadState, action: @escaping () -> Void) {
      self.state = state
      self.action = action
    }

    public var body: some View {
      Button(action: action) {
        ZStack {
          if case .downloading(let progress) = state {
            Gauge(value: min(max(progress, 0), 1)) {
              EmptyView()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(PutioTheme.Colors.accent)
          }
          glyph
        }
        .frame(minWidth: target, minHeight: target)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityValue(accessibilityValue)
    }

    private var glyph: some View {
      Image(systemName: glyphName)
        .font(.system(size: glyphSize, weight: .regular))
        .foregroundStyle(glyphColor)
    }

    private var glyphName: String {
      switch state {
      case .idle, .failed: "arrow.down"
      case .queued: "clock"
      case .downloading: "stop.fill"
      case .downloaded: "checkmark.circle.fill"
      }
    }

    private var glyphSize: CGFloat {
      switch state {
      case .idle, .queued, .failed: actionGlyphSize
      case .downloading: stopGlyphSize
      case .downloaded: doneGlyphSize
      }
    }

    private var glyphColor: Color {
      switch state {
      case .idle, .queued, .failed: PutioTheme.Colors.textDisabled
      case .downloading: PutioTheme.Colors.textPrimary
      case .downloaded: PutioTheme.Colors.accent
      }
    }

    // Failed shares the idle glyph visually (ios-s02), but VoiceOver names
    // the action the tap performs, so it announces the retry.
    private var accessibilityLabel: Text {
      switch state {
      case .idle: Text("Download")
      case .queued: Text("Queued")
      case .downloading: Text("Stop download")
      case .downloaded: Text("Downloaded")
      case .failed: Text("Retry download")
      }
    }

    private var accessibilityValue: Text {
      if case .downloading(let progress) = state {
        return Text(min(max(progress, 0), 1), format: .percent.precision(.fractionLength(0)))
      }
      return Text("")
    }
  }

  enum PutioDownloadStateLayout {
    static let target = PutioMetricRole(value: 44, relativeTo: .body)
    static let actionGlyph = PutioMetricRole(value: 20, relativeTo: .body)
    static let stopGlyph = PutioMetricRole(value: 14, relativeTo: .body)
    static let doneGlyph = PutioMetricRole(value: 22, relativeTo: .body)
  }
#endif
