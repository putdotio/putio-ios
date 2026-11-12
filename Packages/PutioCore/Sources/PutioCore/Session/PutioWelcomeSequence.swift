import SwiftUI

public enum PutioWelcomeSequence {
  public static let holdMilliseconds = 1_900
  public static let rollMilliseconds = 600
  public static let frameMilliseconds = holdMilliseconds + rollMilliseconds

  static let rollCurve = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.7, y: 0),
    endControlPoint: UnitPoint(x: 0.2, y: 1)
  )

  public static func position(elapsed: TimeInterval, frameCount: Int) -> Double {
    guard frameCount > 1, elapsed > 0 else { return 0 }
    let milliseconds = Int((elapsed * 1_000).rounded())
    let frame = (milliseconds / frameMilliseconds) % frameCount
    let rolled = max(0, milliseconds % frameMilliseconds - holdMilliseconds)
    return Double(frame) + rollCurve.value(at: Double(rolled) / Double(rollMilliseconds))
  }
}
