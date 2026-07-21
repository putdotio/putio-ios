import UIKit
import PutioSDK

class TrashTableViewCell: UITableViewCell {
    func configure(with trashFile: PutioTrashFile) {
        imageView?.tintColor = UIColor.Putio.listSubtitle

        switch trashFile.type {
        case .folder:
            imageView?.image = PutioIcon.folderFill.image
            imageView?.tintColor = UIColor.Putio.yellow

        case .video:
            imageView?.image = PutioIcon.fileVideo.image

        case .audio:
            imageView?.image = PutioIcon.fileAudio.image

        default:
            imageView?.image = PutioIcon.file.image
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
