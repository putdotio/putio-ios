import SwiftUI

public enum PutioIcon: String, CaseIterable, Sendable {
  case arrowCircleDown = "arrow-circle-down-regular"
  case arrowCircleDownFill = "arrow-circle-down-fill"
  case arrowCounterClockwise = "arrow-counter-clockwise-regular"
  case arrowSquareOut = "arrow-square-out-regular"
  case caretRight = "caret-right-regular"
  case chatCircle = "chat-circle-regular"
  case checkCircle = "check-circle-regular"
  case checkCircleFill = "check-circle-fill"
  case circle = "circle-regular"
  case clockCountdown = "clock-countdown-regular"
  case clockCounterClockwise = "clock-counter-clockwise-regular"
  case closedCaptioning = "closed-captioning-regular"
  case deviceRotate = "device-rotate-regular"
  case devices = "devices-regular"
  case dotsThree = "dots-three-regular"
  case dotsThreeCircle = "dots-three-circle-regular"
  case downloadSimple = "download-simple-regular"
  case eraser = "eraser-regular"
  case export = "export-regular"
  case eye = "eye-regular"
  case eyeSlash = "eye-slash-regular"
  case file = "file-regular"
  case fileAudio = "file-audio-regular"
  case fileAudioFill = "file-audio-fill"
  case fileFill = "file-fill"
  case fileText = "file-text-regular"
  case fileVideo = "file-video-regular"
  case fileVideoFill = "file-video-fill"
  case folderFill = "folder-fill"
  case folderSimpleDashed = "folder-simple-dashed-regular"
  case folderSimplePlus = "folder-simple-plus-regular"
  case globe = "globe-regular"
  case image = "image-regular"
  case imageFill = "image-fill"
  case info = "info-regular"
  case link = "link-regular"
  case list = "list-regular"
  case listChecks = "list-checks-regular"
  case lockKey = "lock-key-regular"
  case pauseFill = "pause-fill"
  case pencilSimple = "pencil-simple-regular"
  case play = "play-regular"
  case playCircle = "play-circle-regular"
  case playFill = "play-fill"
  case plugs = "plugs-regular"
  case pushPin = "push-pin-regular"
  case screencast = "screencast-regular"
  case shieldCheck = "shield-check-regular"
  case skipForward = "skip-forward-regular"
  case sortAscending = "sort-ascending-regular"
  case star = "star-regular"
  case stopFill = "stop-fill"
  case trash = "trash-regular"
  case trafficCone = "traffic-cone-regular"
  case userCircle = "user-circle-regular"
  case userCircleMinus = "user-circle-minus-regular"
  case warningCircle = "warning-circle-regular"
  case wifiSlash = "wifi-slash-regular"
  case x = "x-regular"
  case xCircle = "x-circle-regular"
  case xCircleFill = "x-circle-fill"
}

extension Image {
  public init(putioIcon: PutioIcon) {
    self.init(putioIcon.rawValue, bundle: .module)
  }
}

extension Image {
  /// The retro put.io wordmark from the design package's `logo-retro-dark.svg`.
  public static var putioWordmark: Image {
    Image("PutioLogoRetroDark", bundle: .module)
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
