import UIKit
import NFDownloadButton
import PutioAPI
import RealmSwift

protocol DownloadsTableViewCellDelegate: class {
    func downloadCellActionButtonTapped(download: Download, sender: DownloadsTableViewCell)
}

class DownloadsTableViewCell: UITableViewCell {
    weak var delegate: DownloadsTableViewCellDelegate?

    let realm = try! Realm()
    var id: Int?

    @IBOutlet weak var icon: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var subtitleLabel: UILabel!
    @IBOutlet weak var downloadButtonContainer: UIView!
    @IBOutlet weak var downloadProgressButton: NFDownloadButton!
    @IBOutlet weak var downloadFinishedButton: NFDownloadButton!

    @IBAction func downloadButtonTapped(_ sender: Any) {
        guard let download = realm.object(ofType: Download.self, forPrimaryKey: id) else {
            return log.error("DownloadsTableViewCell - downloadButtonTapped - invalid download")
        }

        self.delegate?.downloadCellActionButtonTapped(
            download: download,
            sender: self
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        downloadButtonContainer.isHidden = true
    }

    func configure(with downloadId: Int) {
        guard let download = realm.object(ofType: Download.self, forPrimaryKey: downloadId) else {
            return log.error(["configure failed", id as Any, downloadId])
        }

        id = download.id
        titleLabel?.text = download.name
        icon.image = download.fileType == .video ? UIImage.Putio.videoPassive : UIImage.Putio.audioPassive
        selectionStyle = .none
        downloadButtonContainer.isHidden = false

        guard download.state == .completed else {
            downloadProgressButton.isHidden = false
            downloadFinishedButton.isHidden = true

            switch download.state {
            case .queued:
                 downloadProgressButton.downloadState = .willDownload
                 subtitleLabel?.text = "In Queue"
            case .starting:
                 downloadProgressButton.downloadState = .readyToDownload
                 subtitleLabel?.text = "Starting..."
            case .active:
                 downloadProgressButton.downloadPercent = CGFloat((download.progress as NSString).floatValue)
                 subtitleLabel?.text = "Downloading..."
            case .stopped:
                 downloadProgressButton.downloadState = .toDownload
                 subtitleLabel?.text = "Stopped"
            case .failed:
                 downloadProgressButton.downloadState = .toDownload
                 subtitleLabel?.text = "Failed: \(download.message)"
            case .completed:
                break
            }

            return
        }

        subtitleLabel?.text = "\(download.size.bytesToHumanReadable()) - Downloaded \(download.completedAt!.timeAgoSinceDate())"
        icon.image = download.fileType == .video ? UIImage.Putio.video : UIImage.Putio.audio

        downloadProgressButton.isHidden = true
        downloadFinishedButton.isHidden = false

        selectionStyle = .default
    }
}
