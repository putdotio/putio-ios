import UIKit
import PutioAPI

class HistoryTableViewCell: UITableViewCell {
    func configure(with event: PutioHistoryEvent) {
        var text = "No title"
        var detailText = ""
        var icon = "iconMediaGallery"

        switch event.type {
        case .upload:
            let e = event as! PutioUploadEvent
            text = e.fileName
            detailText = "\(e.fileSize.bytesToHumanReadable())  \(e.createdAt.timeAgoSinceDate())"
            icon = "iconUpload"
        case .fileShared:
            let e = event as! PutioFileSharedEvent
            text = e.fileName
            detailText = "\(e.createdAt.timeAgoSinceDate()) - Shared by \(e.sharingUserName)"
            icon = "iconCloudAdd"
        case .transferCompleted:
            let e = event as! PutioTransferCompletedEvent
            text = e.transferName
            detailText = "\(e.transferSize.bytesToHumanReadable())  \(e.createdAt.timeAgoSinceDate())"
            icon = "iconMediaGallery"
        case .transferError:
            let e = event as! PutioTransferErrorEvent
            text = "Error in transfer \(e.transferName)"
            detailText = e.createdAt.timeAgoSinceDate()
            icon = "iconX"
        case .fileFromRSSDeletedError:
            let e = event as! PutioFileFromRSSDeletedErrorEvent
            text = "We had to delete \(e.fileName) per your instructions, since there wasn't enough free space."
            detailText = "\(e.fileSize.bytesToHumanReadable())  \(e.createdAt.timeAgoSinceDate())"
            icon = "iconExclamationPoint"
        case .rssFilterPaused:
            let e = event as! PutioRSSFilterPausedEvent
            text = "\(e.rssFilterTitle) is paused because we couldn't reach the source"
            detailText = e.createdAt.timeAgoSinceDate()
            icon = "iconRSS"
        case .transferFromRSSError:
            let e = event as! PutioTransferFromRSSErrorEvent
            text = "Error in transfer from RSS for \(e.transferName)"
            detailText = e.createdAt.timeAgoSinceDate()
            icon = "iconX"
        case .transferCallbackError:
            let e = event as! PutioTransferCallbackErrorEvent
            text = "Error in transfer callback for \(e.transferName)"
            detailText = e.createdAt.timeAgoSinceDate()
            icon = "iconX"
        default:
            break
        }

        textLabel?.text = text
        detailTextLabel?.text = detailText
        imageView?.image = UIImage(named: icon)
    }
}
