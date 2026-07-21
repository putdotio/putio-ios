import UIKit
import PutioSDK

class TrashTableViewCell: UITableViewCell {
    func configure(with trashFile: PutioTrashFile) {
        imageView?.contentMode = .scaleAspectFit
        imageView?.tintColor = UIColor.Putio.Neutral.textSecondary

        switch trashFile.type {
        case .folder:
            imageView?.image = PutioIcon.folderFill.image(pointSize: 20)
            imageView?.tintColor = UIColor.Putio.Yellow.solid

        case .video:
            imageView?.image = PutioIcon.fileVideo.image(pointSize: 20)

        case .audio:
            imageView?.image = PutioIcon.fileAudio.image(pointSize: 20)

        default:
            imageView?.image = PutioIcon.file.image(pointSize: 20)
        }

        textLabel?.text = trashFile.name

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        detailTextLabel?.text = String(
            format: NSLocalizedString("%@ - Expires on %@", comment: ""),
            trashFile.size.bytesToHumanReadable(),
            formatter.string(from: trashFile.expiresOn)
        )
    }
}
