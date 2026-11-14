import Foundation
import Observation

public enum PutioVideoPlayerActivity: Equatable, Sendable {
  case paused
  case waiting
  case playing
}

public enum PutioVideoWait: Equatable, Sendable {
  case preparing
  case clear
  case buffering
  case bufferingLong
  case stalled

  public var showsSpinner: Bool {
    self == .buffering || self == .bufferingLong
  }

  public var hidesControls: Bool {
    self == .preparing || self == .stalled
  }
}

public typealias PutioVideoWaitSleep = @MainActor @Sendable (Duration) async throws -> Void

@MainActor
@Observable
public final class PutioVideoWaitModel {
  public static let labelDelay = Duration.seconds(10)
  public static let stallDelay = Duration.seconds(30)

  public private(set) var state: PutioVideoWait = .preparing

  @ObservationIgnored private let sleep: PutioVideoWaitSleep
  @ObservationIgnored private var timer: Task<Void, Never>?
  @ObservationIgnored private var generation: UInt64 = 0

  public init(sleep: @escaping PutioVideoWaitSleep = { try await Task.sleep(for: $0) }) {
    self.sleep = sleep
  }

  public func activityChanged(_ activity: PutioVideoPlayerActivity) {
    switch (state, activity) {
    case (.preparing, .playing), (.stalled, .playing):
      settle(.clear)
    case (.preparing, _), (.stalled, _), (.buffering, .waiting), (.bufferingLong, .waiting):
      return
    case (.clear, .waiting):
      startBuffering()
    case (_, .paused), (_, .playing):
      settle(.clear)
    }
  }

  public func restart() {
    settle(.preparing)
  }

  public func cancel() {
    generation &+= 1
    timer?.cancel()
    timer = nil
  }

  private func settle(_ state: PutioVideoWait) {
    cancel()
    self.state = state
  }

  private func startBuffering() {
    settle(.buffering)
    let generation = generation
    let sleep = sleep
    timer = Task { @MainActor [weak self] in
      do {
        try await sleep(Self.labelDelay)
        guard let self, self.generation == generation else { return }
        state = .bufferingLong
        try await sleep(Self.stallDelay - Self.labelDelay)
        guard self.generation == generation else { return }
        state = .stalled
        timer = nil
      } catch {
        return
      }
    }
  }
}
