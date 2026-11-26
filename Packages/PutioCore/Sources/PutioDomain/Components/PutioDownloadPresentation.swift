import Foundation

public enum PutioDownloadWait: Equatable, Sendable {
  case network
  case storage
}

public enum PutioDownloadDevice: Equatable, Sendable {
  case iPhone
  case iPad
}

public enum PutioDownloadState: Equatable, Sendable {
  case idle
  case downloading(receivedBytes: Int64, totalBytes: Int64)
  case converting(progress: Double)
  case waitingToConvert
  case paused(receivedBytes: Int64, totalBytes: Int64)
  case waiting(PutioDownloadWait, receivedBytes: Int64, totalBytes: Int64)
  case queued(position: Int)
  case removing(on: PutioDownloadDevice)
  case missing
  case failed(reason: String, canRetry: Bool = true)
}

public enum PutioDownloadAction: Equatable, Sendable {
  case pause
  case resume
  case cancel
  case retry
  case downloadAgain
}

public struct PutioDownloadPresentation: Equatable, Sendable {
  public enum Context: Equatable, Sendable {
    case downloads
    case files
  }

  public enum Glyph: Equatable, Sendable {
    case pause
    case play
    case stop
    case again
    case download
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

  public init(
    _ state: PutioDownloadState, context: Context = .downloads, locale: Locale = .current
  ) {
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
      let bytes = Segment(Self.bytesText(received, of: total, locale: locale), isNumeric: true)
      switch context {
      case .downloads:
        statusLine = [bytes, Segment(Self.percentText(fraction, locale: locale), isNumeric: true)]
      case .files:
        statusLine = [
          Segment(String(localized: "Downloading", bundle: .module, locale: locale)), bytes,
        ]
      }
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
    case .waitingToConvert:
      statusLine = [
        Segment(String(localized: "Waiting to convert", bundle: .module, locale: locale))
      ]
      ring = .progress(0, isActive: true, glyph: .pause)
      action = .pause
      progress = 0
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
      let fraction = Self.fraction(received, of: total)
      statusLine = [
        Segment(Self.waitText(wait, locale: locale)),
        Segment(Self.bytesText(received, of: total, locale: locale), isNumeric: true),
      ]
      ring = .progress(fraction, isActive: false, glyph: .pause)
      action = .pause
      progress = fraction
    case .queued(let position):
      statusLine = [
        Segment(String(localized: "Queued · #\(position) in line", bundle: .module, locale: locale))
      ]
      ring = .dashed(glyph: .stop)
      action = .cancel
    case .removing(let device):
      let text =
        switch device {
        case .iPhone:
          String(localized: "Removing from this iPhone…", bundle: .module, locale: locale)
        case .iPad: String(localized: "Removing from this iPad…", bundle: .module, locale: locale)
        }
      statusLine = [Segment(text)]
      dimsRow = true
    case .missing:
      statusLine = [
        Segment(String(localized: "No longer on this iPhone", bundle: .module, locale: locale))
      ]
      ring = .glyph(.download)
      action = .downloadAgain
    case .failed(let reason, let canRetry):
      statusLine = [Segment(reason)]
      tone = .destructive
      if canRetry {
        ring = .glyph(.again)
        action = .retry
      }
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

  public static func bytesText(_ received: Int64, of total: Int64, locale: Locale) -> String {
    guard total > 0 else {
      return PutioFileRowModel.sizeText(bytes: received, locale: locale)
    }
    let unit = ByteUnit(total)
    let totalText = total.formatted(
      ByteCountFormatStyle(style: .file, allowedUnits: unit.allowedUnits, locale: locale))
    let receivedText = (Double(min(max(received, 0), total)) / unit.divisor).formatted(
      .number.precision(.fractionLength(0...unit.fractionDigits)).locale(locale))
    return String(localized: "\(receivedText) of \(totalText)", bundle: .module, locale: locale)
  }

  private static func fraction(_ received: Int64, of total: Int64) -> Double {
    guard total > 0 else { return 0 }
    return min(max(Double(received) / Double(total), 0), 1)
  }

  public static func percentText(_ fraction: Double, locale: Locale) -> String {
    fraction.formatted(
      .percent.precision(.fractionLength(0)).rounded(rule: .down).locale(locale))
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
