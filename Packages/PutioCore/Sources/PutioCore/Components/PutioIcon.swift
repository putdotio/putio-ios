import SwiftUI

public enum PutioIcon: String, CaseIterable, Sendable {
  case arrowCircleDown = "arrow-circle-down-regular"
  case arrowCounterClockwise = "arrow-counter-clockwise-regular"
  case caretRight = "caret-right-regular"
  case checkCircle = "check-circle-regular"
  case clockCounterClockwise = "clock-counter-clockwise-regular"
  case dotsThreeCircle = "dots-three-circle-regular"
  case eye = "eye-regular"
  case file = "file-regular"
  case fileAudio = "file-audio-regular"
  case fileVideo = "file-video-regular"
  case folderFill = "folder-fill"
  case image = "image-regular"
  case info = "info-regular"
  case trash = "trash-regular"
  case userCircle = "user-circle-regular"
  case warningCircle = "warning-circle-regular"
  case xCircle = "x-circle-regular"
}

extension Image {
  public init(putioIcon: PutioIcon) {
    self.init(putioIcon.rawValue, bundle: .module)
  }
}

public struct PutioIconView: View {
  private let icon: PutioIcon
  @PutioScaledMetric private var size: CGFloat

  public init(_ icon: PutioIcon, size: PutioMetricRole) {
    self.icon = icon
    _size = PutioScaledMetric(size)
  }

  public var body: some View {
    Image(putioIcon: icon)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
  }
}
