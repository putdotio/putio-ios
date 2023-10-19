import UIKit
import PutioAPI

class TrashTableViewCell: UITableViewCell {
    func configure(with trashFile: PutioTrashFile) {
        switch trashFile.type {
        case .folder:
            imageView?.image = UIImage.Putio.folder

        case .video:
            imageView?.image = UIImage.Putio.video

        case .audio:
            imageView?.image = UIImage.Putio.audio

        default:
            imageView?.image = UIImage.Putio.file
        }

        textLabel?.text = trashFile.name

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        detailTextLabel?.text = "\(trashFile.size.bytesToHumanReadable()) - Expires on \(formatter.string(from: trashFile.expiresOn))"
    }
}
