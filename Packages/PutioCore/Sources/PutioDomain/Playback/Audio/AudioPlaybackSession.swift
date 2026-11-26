import Observation

/// Playback belongs to the signed-in tab shell, not its dismissible sheet.
@MainActor
@Observable
public final class PutioAudioPlaybackSession {
  public private(set) var model: PutioAudioPlayerModel?
  public var isPresented = false
  public let sleepTimer: PutioAudioSleepTimer
  @ObservationIgnored private var startTask: Task<Void, Never>?

  public init(sleepTimer: PutioAudioSleepTimer) {
    self.sleepTimer = sleepTimer
    sleepTimer.onExpire = { [weak self] in self?.model?.sleepTimerExpired() }
  }

  public func present(_ model: PutioAudioPlayerModel) {
    retire()
    self.model = model
    isPresented = true
    startTask = Task { await model.start() }
  }

  public func stop() {
    sleepTimer.cancel()
    retire()
  }

  public func retire() {
    startTask?.cancel()
    startTask = nil
    model?.stop()
    model = nil
    isPresented = false
  }
}
