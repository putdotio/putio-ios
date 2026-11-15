import UIKit

/// Holds a tall phone window in landscape while a video plays, either side
/// up, and returns it to portrait afterwards. UIKit reads the allowed
/// orientations from the app delegate, so the lock lives there. iPad windows
/// can be resized under multitasking and keep every orientation.
@MainActor
enum PutioVideoOrientationLock {
  private static var isLocked = false

  static var supportedOrientations: UIInterfaceOrientationMask {
    guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
    return isLocked ? .landscape : .allButUpsideDown
  }

  static func setLocked(_ locked: Bool) {
    guard UIDevice.current.userInterfaceIdiom == .phone else { return }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let phone = scenes.filter { $0.session.role == .windowApplication }
    let player = phone.first { $0.activationState == .foregroundActive } ?? phone.first
    let locksLandscape = locked && player.map { isTall($0.coordinateSpace.bounds.size) } == true
    guard locksLandscape != isLocked else { return }
    isLocked = locksLandscape
    for scene in phone {
      scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
      scene.requestGeometryUpdate(
        .iOS(interfaceOrientations: locksLandscape ? .landscape : .portrait))
    }
  }

  private static func isTall(_ size: CGSize) -> Bool {
    let short = min(size.width, size.height)
    return short > 0 && max(size.width, size.height) / short >= rotatingAspect
  }

  private static let rotatingAspect: CGFloat = 1.6
}
