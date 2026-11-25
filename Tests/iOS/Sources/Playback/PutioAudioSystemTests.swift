import AVFoundation
import MediaPlayer
import PutioCore
import UIKit
import XCTest

@testable import Putio

@MainActor
final class PutioAudioSystemTests: XCTestCase {
  func testSystemSurfaceOffersTenSecondSkipCommandsUntilDetached() {
    let surface = PutioSystemNowPlayingSurface()
    let center = MPRemoteCommandCenter.shared()
    surface.setCommandHandler { _ in }
    defer { surface.detachCommands() }

    for command in [center.skipBackwardCommand, center.skipForwardCommand] {
      XCTAssertTrue(command.isEnabled)
      XCTAssertEqual(command.preferredIntervals, [10])
    }
    surface.detachCommands()
    XCTAssertFalse(center.skipBackwardCommand.isEnabled)
    XCTAssertFalse(center.skipForwardCommand.isEnabled)
  }

  func testSessionEventsMapTheSystemNotificationsTheModelActsOn() async {
    let center = NotificationCenter()
    let events = PutioSystemAudioSessionEvents(notificationCenter: center)
    var received: [PutioAudioSessionEvent] = []
    events.start { received.append($0) }
    defer { events.stop() }

    center.post(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    center.post(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        AVAudioSessionInterruptionOptionKey: UInt(0),
      ])
    center.post(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        AVAudioSessionInterruptionOptionKey:
          AVAudioSession.InterruptionOptions.shouldResume.rawValue,
      ])
    center.post(
      name: AVAudioSession.routeChangeNotification, object: nil,
      userInfo: [
        AVAudioSessionRouteChangeReasonKey:
          AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
      ])
    center.post(
      name: AVAudioSession.routeChangeNotification, object: nil,
      userInfo: [
        AVAudioSessionRouteChangeReasonKey:
          AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
      ])
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

    let deadline = ContinuousClock.now + .seconds(2)
    while received.count < 5, ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertEqual(
      Set(received),
      [
        .interruptionBegan, .interruptionEnded(shouldResume: false),
        .interruptionEnded(shouldResume: true), .outputLost, .enteredBackground,
      ])
    XCTAssertEqual(received.count, 5)

    events.stop()
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    XCTAssertEqual(received.count, 5)
  }
}
