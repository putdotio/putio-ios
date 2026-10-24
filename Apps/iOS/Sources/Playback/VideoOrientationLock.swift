import UIKit

/// Holds a phone in landscape while a video plays, either side up, and
/// returns it to portrait afterwards. UIKit reads the allowed orientations
/// from the app delegate, so the lock lives there. iPad windows can be
/// resized under multitasking and keep every orientation.
@MainActor
enum PutioVideoOrientationLock {
  private static var isLocked = false

  static var supportedOrientations: UIInterfaceOrientationMask {
    guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
    return isLocked ? .landscape : .allButUpsideDown
  }

  static func setLocked(_ locked: Bool) {
    guard UIDevice.current.userInterfaceIdiom == .phone, locked != isLocked else { return }
    isLocked = locked
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: locked ? .landscape : .portrait))
    }
  }
}
