import PutioCore
import SwiftUI
import UIKit
import XCTest

@testable import Putio

@MainActor
final class PlaybackAccessibilityTests: XCTestCase {
  func testCastControlsFitLandscapeAndAccessibilityText() async throws {
    let (model, _) = try await makeCast()
    defer { model.disconnect() }
    for (name, size, textSize) in [
      ("cast-landscape", CGSize(width: 844, height: 390), DynamicTypeSize.large),
      ("cast-accessibility3", CGSize(width: 390, height: 844), DynamicTypeSize.accessibility3),
    ] {
      let window = host(
        PutioCastControlsView(model: model).dynamicTypeSize(textSize), size: size)
      defer { window.isHidden = true }
      let slider = try await slider(in: window)
      let frame = slider.convert(slider.bounds, to: window)
      XCTAssertTrue(
        frame.minX >= 0 && frame.maxX <= window.bounds.width,
        "Playback slider is horizontally clipped in \(name): \(frame)")
      attach(window, name: name)
      let scrollView = try XCTUnwrap(
        scrollAncestor(of: slider), "Overflowing playback controls need a scrollable surface")
      XCTAssertLessThanOrEqual(scrollView.contentSize.width, scrollView.bounds.width + 1)
      let bottom = max(
        0,
        scrollView.contentSize.height - scrollView.bounds.height
          + scrollView.adjustedContentInset.bottom)
      if size.width > size.height {
        XCTAssertGreaterThan(bottom, 0, "Landscape controls must remain reachable by scrolling")
      }
      scrollView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
      window.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
      window.layoutIfNeeded()
      XCTAssertEqual(scrollView.contentOffset.y, bottom, accuracy: 1)
    }
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

  private func scrollAncestor(of view: UIView) -> UIScrollView? {
    guard let parent = view.superview else { return nil }
    return parent as? UIScrollView ?? scrollAncestor(of: parent)
  }

  private func makeCast() async throws -> (PutioCastModel, AccessibilityCastReceiver) {
    let receiver = AccessibilityCastReceiver()
    let id = PutioFileID(rawValue: 412)
    let media = PutioCastMedia(
      id: id, parentID: .root, title: "Movie.mkv", playbackType: .mp4,
      url: try XCTUnwrap(URL(string: "https://media.example.test/movie.mp4")),
      artworkURL: nil, durationSeconds: 240, startFromSeconds: 60,
      subtitles: [], defaultSubtitleKey: nil)
    let model = PutioCastModel(
      controller: receiver, resolve: { _, _ in .ready(media) }, loadPlaybackType: { .mp4 },
      savePlaybackType: { _ in }, startConversion: { _ in },
      loadConversionStatus: { _ in .completed }, reportPosition: { _, _ in })
    model.cast(PutioVideoRoute(id: id, parentID: .root, title: media.title))
    let deadline = ContinuousClock.now + .seconds(2)
    while model.media == nil || model.activity != .idle, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    _ = try XCTUnwrap(model.media)
    receiver.onMediaStatusChanged?(
      PutioCastMediaStatus(
        fileID: id, playerState: .paused, positionSeconds: 60,
        durationSeconds: 240, activeSubtitleKey: nil))
    return (model, receiver)
  }
}

@MainActor
private final class AccessibilityCastReceiver: PutioCastControlling {
  let connection: PutioCastConnection = .connected(deviceName: "Living Room")
  var onConnectionChanged: ((PutioCastConnection) -> Void)?
  var onMediaStatusChanged: ((PutioCastMediaStatus?) -> Void)?
  let providesSystemCastButton = false

  func presentDevicePicker() {}
  func load(_ media: PutioCastMedia, subtitleKey: String?) async throws {}
  func play() async throws {}
  func pause() async throws {}
  func seek(toSeconds seconds: Double) async throws {}
  func setSubtitle(key: String?) async throws {}
  func stop() async throws {}
  func endSession() { onConnectionChanged?(.disconnected) }
}
