import UIKit

enum PutioIcon: String, CaseIterable {
    case arrowCounterClockwise = "arrow-counter-clockwise-regular"
    case caretRight = "caret-right-regular"
    case chatCircleDots = "chat-circle-dots-regular"
    case chatCircleDotsFill = "chat-circle-dots-fill"
    case clockCounterClockwise = "clock-counter-clockwise-regular"
    case closedCaptioning = "closed-captioning-regular"
    case devices = "devices-regular"
    case envelopeSimple = "envelope-simple-regular"
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
}

extension UIImage {
    struct Putio {
        // File Icons
        static let file = UIImage(named: "iconFile")
        static let folder = UIImage(named: "iconFolder")

        static let video = UIImage(named: "iconVideo")
        static let videoPassive = UIImage(named: "iconVideoPassive")

        static let audio = UIImage(named: "iconAudio")
        static let audioPassive = UIImage(named: "iconAudioPassive")

        // History Icons
        static let mediaGallery = UIImage(named: "iconMediaGallery")
        static let mediaGalleryPassive = UIImage(named: "iconMediaGalleryPassive")

        // Indicator Icons
        static let chevronLeft = UIImage(named: "chevronLeft")
        static let watchedEye = UIImage(named: "eye")
        static let download = UIImage(named: "iconDownload")
        static let downloadPassive = UIImage(named: "iconDownloadPassive")
    }
}
