import PutioCore
import SwiftUI
import UIKit
import XCTest

@testable import Putio

@MainActor
final class PlaybackAccessibilityTests: XCTestCase {
  func testCastingLayoutFitsLandscapeAtExtraLargeText() async throws {
    let (model, _) = try await makeCast()
    defer { model.disconnect() }
    for (name, size, verticalSizeClass) in [
      ("casting-landscape-xxl", CGSize(width: 874, height: 402), UserInterfaceSizeClass.compact),
      ("casting-portrait-xxl", CGSize(width: 402, height: 874), .regular),
    ] {
      let window = host(
        PutioVideoCastingView(model: model, title: "Movie.mkv", onClose: {})
          .environment(\.verticalSizeClass, verticalSizeClass)
          .dynamicTypeSize(.xxLarge),
        size: size)
      defer { window.isHidden = true }
      let slider = try await slider(in: window)
      let frame = slider.convert(slider.bounds, to: window)
      XCTAssertTrue(
        window.bounds.contains(frame), "the scrubber is clipped in \(name): \(frame)")
      attach(window, name: name)
    }
  }

  func testConversionStatusScrollsOnlyWhenItOverflows() async throws {
    let status = PutioConversionStatusView {
      PutioLoadingStateView(title: "Waiting to convert")
    }
    let fitting = host(status.dynamicTypeSize(.large), size: CGSize(width: 390, height: 844))
    defer { fitting.isHidden = true }
    try await settle(fitting)
    XCTAssertNil(findScrollView(in: fitting), "Fitting conversion copy should stay centered")

    let overflowing = host(
      status.dynamicTypeSize(.accessibility5), size: CGSize(width: 844, height: 390))
    defer { overflowing.isHidden = true }
    try await settle(overflowing)
    attach(overflowing, name: "conversion-landscape-accessibility5")
    let scrollView = try XCTUnwrap(
      findScrollView(in: overflowing), "Overflowing conversion copy needs a scrollable surface")
    XCTAssertGreaterThan(scrollView.contentSize.height, scrollView.bounds.height)
  }

  private func settle(_ window: UIWindow) async throws {
    for _ in 0..<20 {
      try await Task.sleep(for: .milliseconds(10))
      window.layoutIfNeeded()
    }
  }

  private func findScrollView(in view: UIView) -> UIScrollView? {
    if let scrollView = view as? UIScrollView { return scrollView }
    return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
  }

  private func host<Content: View>(_ content: Content, size: CGSize) -> UIWindow {
    let controller = UIHostingController(rootView: content.preferredColorScheme(.dark))
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = controller
    window.isHidden = false
    controller.view.frame = window.bounds
    window.layoutIfNeeded()
    return window
  }

  private func attach(_ window: UIWindow, name: String) {
    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
    let image = renderer.image { context in
      window.layer.render(in: context.cgContext)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func slider(in window: UIWindow) async throws -> UISlider {
    let deadline = ContinuousClock.now + .seconds(2)
    while findSlider(in: window) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
      window.layoutIfNeeded()
    }
    return try XCTUnwrap(findSlider(in: window), "Expected the native playback slider")
  }

  private func findSlider(in view: UIView) -> UISlider? {
    if let slider = view as? UISlider { return slider }
    return view.subviews.lazy.compactMap { self.findSlider(in: $0) }.first
  }

  private func makeCast() async throws -> (PutioCastModel, AccessibilityCastReceiver) {
    let receiver = AccessibilityCastReceiver()
    let id = PutioFileID(rawValue: 412)
    let media = PutioCastMedia(
      id: id, parentID: .root, title: "Movie.mkv",
      url: try XCTUnwrap(URL(string: "https://media.example.test/movie.m3u8")),
      artworkURL: nil, durationSeconds: 240, startFromSeconds: 60)
    let model = PutioCastModel(
      controller: receiver, resolve: { _ in .ready(media) }, startConversion: { _ in },
      loadConversionStatus: { _ in .completed })
    model.cast(
      PutioVideoRoute(id: id, parentID: .root, title: media.title),
      saves: PutioCastPositionSaves(
        remembersPosition: false, pipeline: PutioPlaybackPositionPipeline(),
        report: { _, _ in }))
    let deadline = ContinuousClock.now + .seconds(2)
    while model.media == nil || model.activity != .idle, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    _ = try XCTUnwrap(model.media)
    receiver.onMediaStatusChanged?(
      PutioCastMediaStatus(
        fileID: id, playerState: .paused, positionSeconds: 60, durationSeconds: 240))
    return (model, receiver)
  }
}

@MainActor
private final class AccessibilityCastReceiver: PutioCastControlling {
  let connection: PutioCastConnection = .connected(deviceName: "Living Room")
  let discovery = PutioCastDiscovery()
  let approximatePositionSeconds: Double? = nil
  var onConnectionChanged: ((PutioCastConnection) -> Void)?
  var onDiscoveryChanged: ((PutioCastDiscovery) -> Void)?
  var onMediaStatusChanged: ((PutioCastMediaStatus?) -> Void)?

  func startDiscovery() {}
  func connect(toDevice id: PutioCastDevice.ID) {}
  func load(_ media: PutioCastMedia, startSeconds: Int, autoplay: Bool, activeTrackIDs: [Int])
    async throws
  {}
  func setActiveTrackIDs(_ ids: [Int]) async throws {}
  func refreshStatus() {}
  func play() async throws {}
  func pause() async throws {}
  func seek(toSeconds seconds: Double) async throws {}
  func stop() async throws {}
  func endSession() { onConnectionChanged?(.disconnected) }
}
