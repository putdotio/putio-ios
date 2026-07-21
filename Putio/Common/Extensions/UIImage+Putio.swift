import UIKit

enum PutioIconPresentation {
    case navigationBar
    case navigationList
    case tabBar

    var glyphPointSize: CGFloat {
        switch self {
        case .navigationList:
            return 20
        case .navigationBar, .tabBar:
            return 24
        }
    }

    var canvasPointSize: CGFloat {
        switch self {
        case .navigationBar, .navigationList, .tabBar:
            return 24
        }
    }
}

enum PutioIcon: String, CaseIterable {
    case arrowCounterClockwise = "arrow-counter-clockwise-regular"
    case caretRight = "caret-right-regular"
    case chatCircleDots = "chat-circle-dots-regular"
    case chatCircleDotsFill = "chat-circle-dots-fill"
    case checkCircle = "check-circle-regular"
    case checkCircleFill = "check-circle-fill"
    case clock = "clock-regular"
    case clockCounterClockwise = "clock-counter-clockwise-regular"
    case clockCounterClockwiseFill = "clock-counter-clockwise-fill"
    case closedCaptioning = "closed-captioning-regular"
    case cloudArrowDown = "cloud-arrow-down-regular"
    case cloudArrowDownFill = "cloud-arrow-down-fill"
    case cloudArrowUp = "cloud-arrow-up-regular"
    case devices = "devices-regular"
    case dotsThreeCircle = "dots-three-circle-regular"
    case downloadSimple = "download-simple-regular"
    case downloadSimpleFill = "download-simple-fill"
    case envelopeSimple = "envelope-simple-regular"
    case eye = "eye-regular"
    case fastForwardFill = "fast-forward-fill"
    case file = "file-regular"
    case fileAudio = "file-audio-regular"
    case fileVideo = "file-video-regular"
    case folder = "folder-regular"
    case folderFill = "folder-fill"
    case folderPlus = "folder-plus-regular"
    case folderMinus = "folder-minus-regular"
    case hardDrives = "hard-drives-regular"
    case info = "info-regular"
    case imageIcon = "image-regular"
    case key = "key-regular"
    case network = "network-regular"
    case pauseCircleFill = "pause-circle-fill"
    case playFill = "play-fill"
    case playCircleFill = "play-circle-fill"
    case recycle = "recycle-regular"
    case rewindFill = "rewind-fill"
    case rss = "rss-regular"
    case screencast = "screencast-regular"
    case shieldCheck = "shield-check-regular"
    case signOut = "sign-out-regular"
    case sortAscending = "sort-ascending-regular"
    case star = "star-regular"
    case stopFill = "stop-fill"
    case subtitles = "subtitles-regular"
    case televisionSimple = "television-simple-regular"
    case trash = "trash-regular"
    case trashSimple = "trash-simple-regular"
    case uploadSimple = "upload-simple-regular"
    case userCircle = "user-circle-regular"
    case userCircleFill = "user-circle-fill"
    case userCircleMinus = "user-circle-minus-regular"
    case warningCircle = "warning-circle-regular"
    case xCircle = "x-circle-regular"

    var assetName: String {
        "Phosphor/\(rawValue)"
    }

    var image: UIImage? {
        guard let image = UIImage(named: assetName) else {
            InternalFailurePresenter.log("Missing Phosphor icon asset: \(assetName)")
            return nil
        }
        return image
    }

    func image(pointSize: CGFloat) -> UIImage? {
        renderedImage(glyphPointSize: pointSize, canvasPointSize: pointSize)
    }

    func image(for presentation: PutioIconPresentation) -> UIImage? {
        renderedImage(
            glyphPointSize: presentation.glyphPointSize,
            canvasPointSize: presentation.canvasPointSize
        )
    }

    private func renderedImage(glyphPointSize: CGFloat, canvasPointSize: CGFloat) -> UIImage? {
        guard let image else { return nil }
        let canvasSize = CGSize(width: canvasPointSize, height: canvasPointSize)
        let glyphOrigin = CGPoint(
            x: (canvasPointSize - glyphPointSize) / 2,
            y: (canvasPointSize - glyphPointSize) / 2
        )
        let glyphSize = CGSize(width: glyphPointSize, height: glyphPointSize)

        return UIGraphicsImageRenderer(size: canvasSize).image { _ in
            image.draw(in: CGRect(origin: glyphOrigin, size: glyphSize))
        }.withRenderingMode(.alwaysTemplate)
    }
}
