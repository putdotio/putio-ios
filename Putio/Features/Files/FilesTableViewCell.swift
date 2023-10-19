import UIKit
import PutioAPI

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
        colorView.backgroundColor = UIColor.Putio.black
        self.selectedBackgroundView = colorView
        self.multipleSelectionBackgroundView = colorView
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)

        if highlighted {
            contentView.backgroundColor = UIColor.Putio.black
        } else {
            contentView.backgroundColor = UIColor.Putio.background
        }
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        if selected {
            contentView.backgroundColor = UIColor.Putio.black
        } else {
            contentView.backgroundColor = UIColor.Putio.background
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
        title.text = file.name
        subtitleText.text =  "\(file.size.bytesToHumanReadable()) - \(relativeDate)"
        subtitleIcon.isHidden = true
        iconRight.isHidden = true

        switch file.type {
        case .folder:
            icon.image = UIImage.Putio.folder
            iconRight.isHidden = false
            iconRight.image = UIImage.Putio.chevronLeft

        case .video:
            icon.image = UIImage.Putio.video
            if file.startFrom > 0 {
                iconRight.isHidden = false
                iconRight.image = UIImage.Putio.watchedEye
            }

        case .audio:
            icon.image = UIImage.Putio.audio

        default:
            icon.image = UIImage.Putio.file
        }

        if let download = download {
            subtitleIcon.isHidden = false
            subtitleIcon.image = download.state == .completed ? UIImage.Putio.download : UIImage.Putio.downloadPassive
        }
    }
}
