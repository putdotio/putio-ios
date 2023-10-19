import Foundation
import AVFoundation

extension CMTime {
    func getFiniteSeconds() -> Double? {
        let seconds = self.seconds

        guard seconds.isFinite, !seconds.isNaN, !seconds.isInfinite else {
            return nil
        }

        return seconds
    }
}
