import UIKit
import PutioSDK

class FilesTableViewCell: UITableViewCell {
    @IBOutlet weak var icon: UIImageView!
    @IBOutlet weak var title: UILabel!
    @IBOutlet weak var subtitleText: UILabel!
    @IBOutlet weak var subtitleIcon: UIImageView!
    @IBOutlet weak var iconRight: UIImageView!
    var prevIsHidden: Bool!

    override func prepareForReuse() {
        super.prepareForReuse()
        iconRight.isHidden = true
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        let colorView = UIView()
        colorView.backgroundColor = UIColor.Putio.Surface.listItemBgActive
        self.selectedBackgroundView = colorView
        self.multipleSelectionBackgroundView = colorView
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)

        if highlighted {
            contentView.backgroundColor = UIColor.Putio.Surface.listItemBgActive
        } else {
            contentView.backgroundColor = UIColor.Putio.Surface.appBg
        }
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        if selected {
            contentView.backgroundColor = UIColor.Putio.Surface.listItemBgActive
        } else {
            contentView.backgroundColor = UIColor.Putio.Surface.appBg
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)

        if editing {
            prevIsHidden = iconRight.isHidden
            iconRight.isHidden = true
        } else if prevIsHidden != nil {
            iconRight.isHidden = prevIsHidden
        }
    }

    func configure(with file: PutioFile, download: Download?, relativeDate: String) {
        accessibilityIdentifier = "putio-file-\(file.id)"
        accessibilityLabel = file.name
        title.text = file.name
        subtitleText.text = String(
            format: NSLocalizedString("%@ - %@", comment: ""),
            file.size.bytesToHumanReadable(),
            relativeDate
        )
        subtitleIcon.isHidden = true
        iconRight.isHidden = true
        icon.tintColor = UIColor.Putio.Neutral.textSecondary
        iconRight.tintColor = UIColor.Putio.Yellow.solid
        subtitleIcon.tintColor = UIColor.Putio.Neutral.textSecondary

        switch file.type {
        case .folder:
            icon.image = PutioIcon.folderFill.image
            icon.tintColor = UIColor.Putio.Yellow.solid
            iconRight.isHidden = false
            iconRight.image = PutioIcon.caretRight.image

        case .video:
            icon.image = PutioIcon.fileVideo.image
            if file.startFrom > 0 {
                iconRight.isHidden = false
                iconRight.image = PutioIcon.eye.image
            }

        case .audio:
            icon.image = PutioIcon.fileAudio.image

        default:
            icon.image = PutioIcon.file.image
        }

        if let download = download {
            subtitleIcon.isHidden = false
            subtitleIcon.image = download.state == .completed
                ? PutioIcon.downloadSimpleFill.image
                : PutioIcon.downloadSimple.image
            subtitleIcon.tintColor = download.state == .completed
                ? UIColor.Putio.Yellow.textSecondary
                : UIColor.Putio.Neutral.textSecondary
        }
    }
}
