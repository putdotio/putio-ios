import SwiftUI

public enum PutioIcon: String, CaseIterable, Sendable {
  case airplay = "airplay-regular"
  case appWindow = "app-window-regular"
  case arrowCircleDown = "arrow-circle-down-regular"
  case arrowCircleDownFill = "arrow-circle-down-fill"
  case arrowCounterClockwise = "arrow-counter-clockwise-regular"
  case arrowSquareOut = "arrow-square-out-regular"
  case bug = "bug-regular"
  case caretDown = "caret-down-regular"
  case caretLeft = "caret-left-regular"
  case caretRight = "caret-right-regular"
  case chartLine = "chart-line-regular"
  case chatCircle = "chat-circle-regular"
  case checkCircle = "check-circle-regular"
  case checkCircleFill = "check-circle-fill"
  case circle = "circle-regular"
  case clockCounterClockwise = "clock-counter-clockwise-regular"
  case closedCaptioning = "closed-captioning-regular"
  case cloudArrowDown = "cloud-arrow-down-regular"
  case copy = "copy-regular"
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
  case filePdfFill = "file-pdf-fill"
  case fileText = "file-text-regular"
  case fileVideo = "file-video-regular"
  case fileVideoFill = "file-video-fill"
  case filmStrip = "film-strip-regular"
  case folder = "folder-regular"
  case folderFill = "folder-fill"
  case folderSimpleDashed = "folder-simple-dashed-regular"
  case folderSimplePlus = "folder-simple-plus-regular"
  case gauge = "gauge-regular"
  case globe = "globe-regular"
  case image = "image-regular"
  case imageFill = "image-fill"
  case info = "info-regular"
  case link = "link-regular"
  case linkBreak = "link-break-regular"
  case list = "list-regular"
  case listBullets = "list-bullets-regular"
  case listChecks = "list-checks-regular"
  case lockKey = "lock-key-regular"
  case moon = "moon-regular"
  case moonFill = "moon-fill"
  case pauseFill = "pause-fill"
  case pencilSimple = "pencil-simple-regular"
  case pictureInPicture = "picture-in-picture-regular"
  case play = "play-regular"
  case playCircle = "play-circle-regular"
  case playFill = "play-fill"
  case plugs = "plugs-regular"
  case pushPin = "push-pin-regular"
  case pushPinSlash = "push-pin-slash-regular"
  case rss = "rss-regular"
  case screencast = "screencast-regular"
  case shieldCheck = "shield-check-regular"
  case skipBackFill = "skip-back-fill"
  case skipForward = "skip-forward-regular"
  case skipForwardFill = "skip-forward-fill"
  case sortAscending = "sort-ascending-regular"
  case speakerHigh = "speaker-high-regular"
  case star = "star-regular"
  case stopFill = "stop-fill"
  case trash = "trash-regular"
  case trafficCone = "traffic-cone-regular"
  case userCircle = "user-circle-regular"
  case userCircleMinus = "user-circle-minus-regular"
  case users = "users-regular"
  case warningCircle = "warning-circle-regular"
  case warningCircleFill = "warning-circle-fill"
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

#if canImport(UIKit)
  extension Image {
    public init(putioIcon: PutioIcon, fixed color: Color) {
      guard let image = UIImage(named: putioIcon.rawValue, in: .module, with: nil)?.fixed(color)
      else {
        self.init(putioIcon: putioIcon)
        return
      }
      self.init(uiImage: image)
    }

    public init(systemName: String, fixed color: Color) {
      guard let image = UIImage(systemName: systemName)?.fixed(color) else {
        self.init(systemName: systemName)
        return
      }
      self.init(uiImage: image)
    }
  }

  extension UIImage {
    public func fixed(_ color: Color) -> UIImage {
      withTintColor(UIColor(color), renderingMode: .alwaysOriginal)
    }
  }
#endif

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
