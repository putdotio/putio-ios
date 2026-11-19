import Foundation
import PutioSDK

/// What a resolved plan plays, kept with the source so a failure report
/// names it without reading the URL.
public struct PutioPlaybackFacts: Equatable, Sendable {
  public enum SourceKind: String, Sendable {
    case hls
    case converted
    case original
    case localFile = "local_file"
  }

  public enum DeviceCheck: String, Sendable {
    case pass
    case fail
    case skipped
  }

  public let method: PutioPlaybackMethod?
  public let sourceKind: SourceKind?
  public let deviceCheck: DeviceCheck?
  public let media: PutioPlaybackMedia

  public init(
    method: PutioPlaybackMethod?, sourceKind: SourceKind?, deviceCheck: DeviceCheck?,
    media: PutioPlaybackMedia = .unknown
  ) {
    self.method = method
    self.sourceKind = sourceKind
    self.deviceCheck = deviceCheck
    self.media = media
  }

  public static let unknown = PutioPlaybackFacts(method: nil, sourceKind: nil, deviceCheck: nil)

  public static func download(method: PutioPlaybackMethod?) -> PutioPlaybackFacts {
    PutioPlaybackFacts(method: method, sourceKind: .localFile, deviceCheck: .skipped)
  }

  static let standard = PutioPlaybackFacts(
    method: .standard, sourceKind: .hls, deviceCheck: .skipped)

  /// The Direct play device check runs on the original only; the converted
  /// copy is trusted without one.
  static func directPlay(_ stream: PutioPlaybackStream) -> PutioPlaybackFacts {
    let media = PutioPlaybackMedia(stream.mediaInfo)
    switch stream.kind {
    case .original:
      return PutioPlaybackFacts(
        method: .directPlay, sourceKind: .original, deviceCheck: .pass, media: media)
    case .mp4:
      return PutioPlaybackFacts(
        method: .directPlay, sourceKind: .converted, deviceCheck: .skipped, media: media)
    case .hls:
      return PutioPlaybackFacts(
        method: .directPlay, sourceKind: .hls, deviceCheck: .skipped, media: media)
    }
  }
}

/// The original's `media_info` as report tags: its first video stream,
/// lowercased, and its default audio stream.
public struct PutioPlaybackMedia: Equatable, Sendable {
  public let containerFamily: String
  public let videoCodec: String
  public let videoProfile: String
  public let videoLevel: String
  public let videoBitDepth: String
  public let videoResolution: String
  public let videoHDR: String
  public let audioCodec: String
  public let audioChannels: String

  static let unknownValue = "unknown"
  static let noneValue = "none"

  public static let unknown = PutioPlaybackMedia(nil)

  init(_ info: PutioMediaInfo?) {
    guard let info else {
      containerFamily = Self.unknownValue
      videoCodec = Self.unknownValue
      videoProfile = Self.unknownValue
      videoLevel = Self.unknownValue
      videoBitDepth = Self.unknownValue
      videoResolution = Self.unknownValue
      videoHDR = Self.unknownValue
      audioCodec = Self.unknownValue
      audioChannels = Self.unknownValue
      return
    }
    containerFamily = Self.containerFamily(format: info.format?.name, mimeType: info.mimeType)
    let video = info.streams.first { $0.codecType == .video }
    let audio = info.defaultAudioStream
    func value<T>(
      _ stream: PutioMediaStream?, lowercased: Bool = true, _ field: (PutioMediaStream) -> T?
    ) -> String {
      guard let stream else { return Self.noneValue }
      guard let found = field(stream) else { return Self.unknownValue }
      let text = lowercased ? "\(found)".lowercased() : "\(found)"
      return text.isEmpty ? Self.unknownValue : text
    }
    videoCodec = value(video) { $0.codecName }
    videoProfile = value(video) { $0.profile }
    videoLevel = value(video) { $0.level }
    videoBitDepth = value(video) { $0.bitDepth }
    videoResolution = value(video) { stream in
      stream.width.flatMap { width in stream.height.map { "\(width)x\($0)" } }
    }
    videoHDR = value(video) { $0.isHDR }
    audioCodec = value(audio, lowercased: false) { $0.codecName }
    audioChannels = value(audio) { $0.channels }
  }

  /// ffprobe names Matroska and WebM alike, so the MIME type tells them apart.
  static func containerFamily(format: String?, mimeType: String?) -> String {
    guard let format = format?.lowercased(), !format.isEmpty else { return unknownValue }
    let names = Set(format.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    if names.contains("matroska") || names.contains("webm") {
      return mimeType?.lowercased() == "video/webm" ? "webm" : "matroska"
    }
    if !names.isDisjoint(with: ["mov", "mp4", "m4a", "m4v", "3gp", "3g2", "mj2"]) { return "mp4" }
    if names.contains("avi") { return "avi" }
    if names.contains("mpegts") { return "mpeg-ts" }
    if names.contains("ogg") { return "ogg" }
    return "other"
  }
}

public enum PutioPlaybackFailureMode: String, Sendable {
  case sourceGone = "source_gone"
  case entitlement
  case throttled
  case serverTransient = "server_transient"
  case network
  case load
  case decode
  case unsupportedSource = "unsupported_source"
  case drm
  case aborted
  case unknown

  /// A definitive source status outranks the engine's own code.
  static func status(_ status: Int?) -> PutioPlaybackFailureMode? {
    switch status {
    case 404?, 410?: .sourceGone
    case 402?: .entitlement
    case 429?: .throttled
    case 408?: .serverTransient
    case let status? where (500..<600).contains(status): .serverTransient
    case let status? where (400..<500).contains(status): .load
    default: nil
    }
  }
}

/// One player failure: the fault the player model acts on, and the engine's
/// own classification for the failure report.
public struct PutioPlayerError: Equatable, Sendable {
  public enum Engine: String, Sendable {
    case avPlayer = "avplayer"
    /// The Direct play engine, AetherEngine.
    case aether
  }

  public let engine: Engine
  public let fault: PutioVideoPlayerFault
  public let mode: PutioPlaybackFailureMode
  public let domain: String?
  public let category: String?
  public let code: Int?
  public let requestStatus: Int?

  /// An `AVPlayerItem` error. AVFoundation's generic -11800 wraps the error
  /// that names the cause, so that one is reported instead.
  public init(avPlayerError error: Error?) {
    engine = .avPlayer
    fault = PutioVideoPlayerFault(error: error)
    let chain = PutioVideoPlayerFault.chain(from: error.map { $0 as NSError })
    let reported =
      chain.count > 1 && chain[0].domain == Self.avFoundationDomain
        && chain[0].code == Self.avUnknown ? chain[1] : chain.first
    domain = reported?.domain
    category = nil
    code = reported?.code
    requestStatus =
      chain.contains(where: PutioVideoPlayerFault.isForbidden) ? Self.httpForbidden : nil
    mode =
      PutioPlaybackFailureMode.status(requestStatus)
      ?? Self.mode(of: chain, fault: fault)
  }

  /// AetherEngine's `PlaybackErrorInfo`: its stable kind, and the domain and
  /// code underneath. Refusals carry the HTTP status as the code.
  public init(aetherKind kind: String?, domain: String?, code: Int?) {
    engine = .aether
    self.domain = domain
    self.category = kind
    self.code = code
    let underlying = domain.flatMap { domain in code.map { NSError(domain: domain, code: $0) } }
    if kind == Self.sourceRefused, code == Self.httpForbidden {
      fault = .accessExpired
    } else {
      fault = underlying.map { PutioVideoPlayerFault(error: $0) } ?? .playback
    }
    let refusals: Set<String> = [Self.sourceRefused, Self.sourceRateLimited]
    requestStatus = kind.flatMap { refusals.contains($0) ? code : nil }
    if let statusMode = PutioPlaybackFailureMode.status(requestStatus) {
      mode = statusMode
    } else if fault == .connectionLost {
      mode = .network
    } else if let kind, let kindMode = Self.aetherModes[kind] {
      mode = kindMode
    } else {
      mode = Self.mode(of: underlying.map { [$0] } ?? [], fault: fault)
    }
  }

  private static func mode(of chain: [NSError], fault: PutioVideoPlayerFault)
    -> PutioPlaybackFailureMode
  {
    if chain.contains(where: { $0.domain == NSURLErrorDomain && $0.code == NSURLErrorCancelled }) {
      return .aborted
    }
    if fault == .connectionLost { return .network }
    for error in chain where error.domain == avFoundationDomain {
      if let mode = avFoundationModes[error.code] { return mode }
    }
    return .unknown
  }

  static let avFoundationDomain = "AVFoundationErrorDomain"
  static let avUnknown = -11800
  static let httpForbidden = 403
  static let sourceRefused = "sourceRefused"
  static let sourceRateLimited = "sourceRateLimited"

  /// `AVError.Code` raw values, from AVFoundation's AVError.h.
  static let avFoundationModes: [Int: PutioPlaybackFailureMode] = [
    -11821: .decode,
    -11833: .decode,
    -11839: .decode,
    -11855: .decode,
    -11822: .unsupportedSource,
    -11828: .unsupportedSource,
    -11829: .unsupportedSource,
    -11838: .unsupportedSource,
    -11848: .unsupportedSource,
    -11853: .unsupportedSource,
    -11831: .drm,
    -11835: .drm,
    -11836: .drm,
    -11849: .load,
    -11850: .load,
  ]

  /// AetherEngine's `PlaybackErrorKind` raw values, which it keeps stable.
  static let aetherModes: [String: PutioPlaybackFailureMode] = [
    "sourceCertificateRejected": .network,
    "sourceOpenFailed": .load,
    "vodSourceFailed": .load,
    "sourceFabricatesRanges": .load,
    "reloadFailed": .load,
    "softwarePipelineFailed": .decode,
    "audioBridgeProducedNoOutput": .decode,
    "dolbyVisionRequiresHardware": .unsupportedSource,
    "hlsFormatUnsupported": .unsupportedSource,
  ]
}

/// The `playback_failure` event every put.io player sends, schema 2: one per
/// terminal failure or rescue, anonymous, tags only.
public struct PutioPlaybackFailureReport: Equatable, Sendable {
  public enum Platform: String, Sendable {
    case ios
    case tvos
  }

  public enum Outcome: Equatable, Sendable {
    case failed
    case rescued(reason: String, to: PutioPlaybackFacts.SourceKind)
  }

  public let outcome: Outcome
  public let tags: [String: String]

  public static let tagKeys: Set<String> = [
    "telemetry_event", "schema_version", "platform", "player", "playback_outcome",
    "playback_terminal", "playback_started", "failure_mode", "streaming_method", "source_kind",
    "device_check", "rescue_reason", "rescue_to", "engine_error_domain", "engine_error_category",
    "engine_error_code", "source_request_status", "file_id", "container_family", "video_codec",
    "video_profile", "video_level", "video_bit_depth", "video_resolution", "video_hdr",
    "audio_codec", "audio_channels",
  ]

  static let event = "playback_failure"
  static let schemaVersion = "2"

  public init(
    platform: Platform, fileID: PutioFileID, source: PutioPlaybackSource, error: PutioPlayerError,
    playbackStarted: Bool, outcome: Outcome
  ) {
    self.outcome = outcome
    let facts = source.facts
    let unknown = PutioPlaybackMedia.unknownValue
    let none = PutioPlaybackMedia.noneValue
    var tags = [
      "telemetry_event": Self.event,
      "schema_version": Self.schemaVersion,
      "platform": platform.rawValue,
      "player": error.engine.rawValue,
      "playback_started": String(playbackStarted),
      "failure_mode": error.mode.rawValue,
      "streaming_method": facts.method?.rawValue ?? unknown,
      "source_kind": facts.sourceKind?.rawValue ?? unknown,
      "device_check": facts.deviceCheck?.rawValue ?? unknown,
      "engine_error_domain": error.domain ?? none,
      "engine_error_category": error.category ?? none,
      "engine_error_code": error.code.map(String.init) ?? none,
      "source_request_status": error.requestStatus.map(String.init) ?? none,
      "file_id": String(fileID.rawValue),
      "container_family": facts.media.containerFamily,
      "video_codec": facts.media.videoCodec,
      "video_profile": facts.media.videoProfile,
      "video_level": facts.media.videoLevel,
      "video_bit_depth": facts.media.videoBitDepth,
      "video_resolution": facts.media.videoResolution,
      "video_hdr": facts.media.videoHDR,
      "audio_codec": facts.media.audioCodec,
      "audio_channels": facts.media.audioChannels,
    ]
    switch outcome {
    case .failed:
      tags["playback_outcome"] = "failed"
      tags["playback_terminal"] = "true"
      tags["rescue_reason"] = none
      tags["rescue_to"] = none
    case .rescued(let reason, let target):
      tags["playback_outcome"] = "rescued"
      tags["playback_terminal"] = "false"
      tags["rescue_reason"] = reason
      tags["rescue_to"] = target.rawValue
    }
    self.tags = tags
  }

  public var isRescue: Bool {
    if case .rescued = outcome { return true }
    return false
  }

  public var message: String { Self.message(tags: tags) }
  public var fingerprint: [String] { Self.fingerprint(tags: tags) }

  /// Built from tags alone, so the allowlist can rebuild it from what it keeps.
  public static func message(tags: [String: String]) -> String {
    "playback \(tags["playback_outcome"] ?? "unknown"): \(cause(tags))"
  }

  public static func fingerprint(tags: [String: String]) -> [String] {
    [
      tags["platform"] ?? "unknown", tags["playback_outcome"] ?? "unknown", cause(tags),
      tags["engine_error_code"] ?? "none",
    ]
  }

  public static func isPlaybackFailure(tags: [String: String]?) -> Bool {
    tags?["telemetry_event"] == event
  }

  private static func cause(_ tags: [String: String]) -> String {
    let key = tags["playback_outcome"] == "rescued" ? "rescue_reason" : "failure_mode"
    return tags[key] ?? "unknown"
  }
}
