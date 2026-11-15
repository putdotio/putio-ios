#if DEBUG
  import Foundation
  import Observation
  import PutioCore
  import SwiftUI

  /// A deterministic receiver for the seeded journey: a TV and a speaker that
  /// discovery keeps looking past, and a clock that advances while "playing".
  /// Load can be made to fail once so retry is proven.
  @MainActor
  @Observable
  final class PutioHarnessCastController: PutioCastControlling {
    static let tv = PutioCastDevice(
      id: "living-room-tv", name: "Living Room TV", model: "Chromecast with Google TV",
      kind: .tv, audioOnly: false, isSelected: false)
    static let speaker = PutioCastDevice(
      id: "kitchen-speaker", name: "Kitchen speaker", model: "Google Nest Audio",
      kind: .speaker, audioOnly: true, isSelected: false)

    private(set) var connection: PutioCastConnection = .disconnected
    private(set) var discovery: PutioCastDiscovery
    @ObservationIgnored var onConnectionChanged: ((PutioCastConnection) -> Void)?
    @ObservationIgnored var onDiscoveryChanged: ((PutioCastDiscovery) -> Void)?
    @ObservationIgnored var onMediaStatusChanged: ((PutioCastMediaStatus?) -> Void)?
    private(set) var loaded: PutioCastMedia?
    @ObservationIgnored private var state: PutioCastPlayerState = .idle
    @ObservationIgnored private var position: Double = 0
    @ObservationIgnored private var activeSubtitleKey: String?
    @ObservationIgnored private var failuresRemaining: Int
    @ObservationIgnored private var clock: Task<Void, Never>?

    /// Gallery and exercised launches configure no Cast context and show no
    /// Cast control, so their stub reports no receiver at all.
    init(failLoadsBeforeSuccess: Int = 0, connection: PutioCastConnection = .disconnected) {
      failuresRemaining = failLoadsBeforeSuccess
      self.connection = connection
      discovery = PutioCastDiscovery(devices: [Self.tv, Self.speaker], isSearching: true)
    }

    func startDiscovery() {}

    func connect(toDevice id: PutioCastDevice.ID) {
      guard let device = discovery.devices.first(where: { $0.id == id }) else { return }
      if connection.deviceName != nil { endSession() }
      select(id)
      set(.connecting(deviceName: device.name))
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(300))
        guard let self, case .connecting = connection else { return }
        set(.connected(deviceName: device.name))
      }
    }

    private func select(_ id: PutioCastDevice.ID?) {
      discovery.devices = discovery.devices.map {
        PutioCastDevice(
          id: $0.id, name: $0.name, model: $0.model, kind: $0.kind, audioOnly: $0.audioOnly,
          isSelected: $0.id == id)
      }
      onDiscoveryChanged?(discovery)
    }

    func load(_ media: PutioCastMedia, subtitleKey: String?) async throws {
      guard connection.isConnected else { throw PutioCastControllerError(failure: .receiver) }
      try await Task.sleep(for: .milliseconds(400))
      if failuresRemaining > 0 {
        failuresRemaining -= 1
        throw PutioCastControllerError(failure: .receiver)
      }
      loaded = media
      position = Double(media.startFromSeconds)
      activeSubtitleKey = subtitleKey
      state = .playing
      publish()
      startClock()
    }

    func play() async throws {
      guard loaded != nil else { throw PutioCastControllerError(failure: .receiver) }
      state = .playing
      publish()
      startClock()
    }

    func pause() async throws {
      guard loaded != nil else { throw PutioCastControllerError(failure: .receiver) }
      state = .paused
      clock?.cancel()
      publish()
    }

    func seek(toSeconds seconds: Double) async throws {
      guard let loaded else { throw PutioCastControllerError(failure: .receiver) }
      position = min(max(0, seconds), loaded.durationSeconds)
      publish()
    }

    func setSubtitle(key: String?) async throws {
      guard loaded != nil else { throw PutioCastControllerError(failure: .receiver) }
      activeSubtitleKey = key
      publish()
    }

    func stop() async throws {
      clock?.cancel()
      loaded = nil
      state = .idle
      onMediaStatusChanged?(nil)
    }

    func endSession() {
      clock?.cancel()
      loaded = nil
      state = .idle
      select(nil)
      set(.disconnected)
    }

    private func set(_ next: PutioCastConnection) {
      connection = next
      onConnectionChanged?(next)
    }

    private func startClock() {
      clock?.cancel()
      clock = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          guard let self, !Task.isCancelled, state == .playing, let loaded else { return }
          position = min(position + 1, loaded.durationSeconds)
          publish()
        }
      }
    }

    private func publish() {
      guard let loaded else {
        onMediaStatusChanged?(nil)
        return
      }
      onMediaStatusChanged?(
        PutioCastMediaStatus(
          fileID: loaded.id, playerState: state, positionSeconds: position,
          durationSeconds: loaded.durationSeconds, activeSubtitleKey: activeSubtitleKey))
    }
  }

  /// Exposes the last rendered position report so the journey can assert the
  /// throttled sync without reading network traffic.
  struct HarnessCastPositionProbe: View {
    let fileID: PutioFileID
    let seconds: Int

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cast position reported")
        .accessibilityValue("id=\(fileID.rawValue);seconds=\(seconds)")
        .accessibilityIdentifier("cast.position-reported")
        .allowsHitTesting(false)
    }
  }
#endif
