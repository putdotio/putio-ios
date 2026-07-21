import UIKit

enum PutioIcon: String, CaseIterable {
    case arrowCounterClockwise = "arrow-counter-clockwise-regular"
    case caretRight = "caret-right-regular"
    case chatCircleDots = "chat-circle-dots-regular"
    case chatCircleDotsFill = "chat-circle-dots-fill"
    case clockCounterClockwise = "clock-counter-clockwise-regular"
    case clockCounterClockwiseFill = "clock-counter-clockwise-fill"
    case closedCaptioning = "closed-captioning-regular"
    case cloudArrowDown = "cloud-arrow-down-regular"
    case cloudArrowDownFill = "cloud-arrow-down-fill"
    case devices = "devices-regular"
    case downloadSimple = "download-simple-regular"
    case downloadSimpleFill = "download-simple-fill"
    case envelopeSimple = "envelope-simple-regular"
    case eye = "eye-regular"
    case file = "file-regular"
    case fileAudio = "file-audio-regular"
    case fileVideo = "file-video-regular"
    case folder = "folder-regular"
    case folderFill = "folder-fill"
    case folderMinus = "folder-minus-regular"
    case hardDrives = "hard-drives-regular"
    case info = "info-regular"
    case key = "key-regular"
    case network = "network-regular"
    case recycle = "recycle-regular"
    case screencast = "screencast-regular"
    case shieldCheck = "shield-check-regular"
    case signOut = "sign-out-regular"
    case sortAscending = "sort-ascending-regular"
    case star = "star-regular"
    case subtitles = "subtitles-regular"
    case televisionSimple = "television-simple-regular"
    case trash = "trash-regular"
    case userCircle = "user-circle-regular"
    case userCircleFill = "user-circle-fill"
    case userCircleMinus = "user-circle-minus-regular"

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
        guard let image else { return nil }
        let size = CGSize(width: pointSize, height: pointSize)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysTemplate)
    }
}

extension UIImage {
    struct Putio {
        // Removed with the Downloads migration.
        static let video = PutioIcon.fileVideo.image
        static let videoPassive = PutioIcon.fileVideo.image
        static let audio = PutioIcon.fileAudio.image
        static let audioPassive = PutioIcon.fileAudio.image

        // History Icons
        static let mediaGallery = UIImage(named: "iconMediaGallery")
        static let mediaGalleryPassive = UIImage(named: "iconMediaGalleryPassive")
    }
}
