#if DEBUG
  import Foundation
  import Observation
  import PutioCore
  import SwiftUI

  /// A deterministic receiver for the seeded journey: one fake device, a
  /// picker sheet driven by the app, and a clock that advances while
  /// "playing". Load can be made to fail once so retry is proven.
  @MainActor
  @Observable
  final class PutioHarnessCastController: PutioCastControlling {
    static let deviceName = "Harness TV"

    private(set) var connection: PutioCastConnection = .disconnected
    @ObservationIgnored var onConnectionChanged: ((PutioCastConnection) -> Void)?
    @ObservationIgnored var onMediaStatusChanged: ((PutioCastMediaStatus?) -> Void)?
    @ObservationIgnored let providesSystemCastButton = false
    /// The app observes this to present the stub picker.
    var presentsPicker = false
    @ObservationIgnored private(set) var loaded: PutioCastMedia?
    @ObservationIgnored private var state: PutioCastPlayerState = .idle
    @ObservationIgnored private var position: Double = 0
    @ObservationIgnored private var activeSubtitleKey: String?
    @ObservationIgnored private var failuresRemaining: Int
    @ObservationIgnored private var clock: Task<Void, Never>?

    init(failLoadsBeforeSuccess: Int = 0) {
      failuresRemaining = failLoadsBeforeSuccess
    }

    func presentDevicePicker() {
      presentsPicker = true
    }

    func connectToHarnessDevice() {
      presentsPicker = false
      set(.connecting(deviceName: Self.deviceName))
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(300))
        guard let self, case .connecting = connection else { return }
        set(.connected(deviceName: Self.deviceName))
      }
    }

    func dismissPicker() {
      presentsPicker = false
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

  /// The stub device picker, standing in for Google's dialog.
  struct PutioHarnessCastPicker: View {
    let controller: PutioHarnessCastController

    var body: some View {
      NavigationStack {
        List {
          Button {
            controller.connectToHarnessDevice()
          } label: {
            Label(PutioHarnessCastController.deviceName, systemImage: "tv")
          }
          .accessibilityIdentifier("cast.picker.device")
        }
        .putioContentBackground()
        .navigationTitle("Cast to")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { controller.dismissPicker() }
              .accessibilityIdentifier("cast.picker.cancel")
          }
        }
      }
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
