import UIKit
import PutioSDK

struct HistoryEventPresentation {
    let text: String
    let detailText: String
    let icon: PutioIcon

    static func build(from event: PutioHistoryEvent) -> HistoryEventPresentation? {
        switch event.type {
        case .upload:
            return uploadPresentation(from: event)
        case .fileShared:
            return fileSharedPresentation(from: event)
        case .transferCompleted:
            return transferCompletedPresentation(from: event)
        case .transferError:
            return transferErrorPresentation(from: event)
        case .fileFromRSSDeletedError:
            return fileFromRSSDeletedErrorPresentation(from: event)
        case .rssFilterPaused:
            return rssFilterPausedPresentation(from: event)
        case .transferFromRSSError:
            return transferFromRSSErrorPresentation(from: event)
        case .transferCallbackError:
            return transferCallbackErrorPresentation(from: event)
        default:
            return HistoryEventPresentation(
                text: NSLocalizedString("No title", comment: ""),
                detailText: "",
                icon: .imageIcon
            )
        }
    }

    private static func uploadPresentation(from event: PutioHistoryEvent) -> HistoryEventPresentation? {
        guard let event = event as? PutioUploadEvent else { return nil }
        return HistoryEventPresentation(
            text: event.fileName,
            detailText: String(
                format: NSLocalizedString("%@  %@", comment: ""),
                event.fileSize.bytesToHumanReadable(),
                event.createdAt.timeAgoSinceDate()
            ),
            icon: .uploadSimple
        )
    }

    private static func fileSharedPresentation(from event: PutioHistoryEvent) -> HistoryEventPresentation? {
        guard let event = event as? PutioFileSharedEvent else { return nil }
        return HistoryEventPresentation(
            text: event.fileName,
            detailText: String(
                format: NSLocalizedString("%@ - Shared by %@", comment: ""),
                event.createdAt.timeAgoSinceDate(),
                event.sharingUserName
            ),
            icon: .cloudArrowUp
        )
    }

    private static func transferCompletedPresentation(from event: PutioHistoryEvent) -> HistoryEventPresentation? {
        guard let event = event as? PutioTransferCompletedEvent else { return nil }
        return HistoryEventPresentation(
            text: event.transferName,
            detailText: String(
                format: NSLocalizedString("%@  %@", comment: ""),
                event.transferSize.bytesToHumanReadable(),
                event.createdAt.timeAgoSinceDate()
            ),
            icon: .checkCircle
        )
    }

    private static func transferErrorPresentation(from event: PutioHistoryEvent) -> HistoryEventPresentation? {
        guard let event = event as? PutioTransferErrorEvent else { return nil }
        return HistoryEventPresentation(
            text: String(
                format: NSLocalizedString("Error in transfer %@", comment: ""),
                event.transferName
            ),
            detailText: event.createdAt.timeAgoSinceDate(),
            icon: .xCircle
        )
    }

    private static func fileFromRSSDeletedErrorPresentation(from event: PutioHistoryEvent) -> HistoryEventPresentation? {
        guard let event = event as? PutioFileFromRSSDeletedErrorEvent else { return nil }
        return HistoryEventPresentation(
            text: String(
                format: NSLocalizedString("We had to delete %@ per your instructions, since there wasn't enough free space.", comment: ""),
                event.fileName
            ),
            detailText: String(
                format: NSLocalizedString("%@  %@", comment: ""),
                event.fileSize.bytesToHumanReadable(),
                event.createdAt.timeAgoSinceDate()
            ),
            icon: .warningCircle
        )
    }

    private static func rssFilterPausedPresentation(from event: PutioHistoryEvent) -> HistoryEventPresentation? {
        guard let event = event as? PutioRSSFilterPausedEvent else { return nil }
        return HistoryEventPresentation(
            text: String(
                format: NSLocalizedString("%@ is paused because we couldn't reach the source", comment: ""),
                event.rssFilterTitle
            ),
            detailText: event.createdAt.timeAgoSinceDate(),
            icon: .rss
        )
    }

    private static func transferFromRSSErrorPresentation(from event: PutioHistoryEvent) -> HistoryEventPresentation? {
        guard let event = event as? PutioTransferFromRSSErrorEvent else { return nil }
        return HistoryEventPresentation(
            text: String(
                format: NSLocalizedString("Error in transfer from RSS for %@", comment: ""),
                event.transferName
            ),
            detailText: event.createdAt.timeAgoSinceDate(),
            icon: .xCircle
        )
    }

    private static func transferCallbackErrorPresentation(from event: PutioHistoryEvent) -> HistoryEventPresentation? {
        guard let event = event as? PutioTransferCallbackErrorEvent else { return nil }
        return HistoryEventPresentation(
            text: String(
                format: NSLocalizedString("Error in transfer callback for %@", comment: ""),
                event.transferName
            ),
            detailText: event.createdAt.timeAgoSinceDate(),
            icon: .xCircle
        )
    }
}

class HistoryTableViewCell: UITableViewCell {
    func configure(with event: PutioHistoryEvent) {
        imageView?.contentMode = .scaleAspectFit
        // Built from code, so awakeFromNib never runs and textLabel /
        // detailTextLabel would keep the system face.
        configureGlobalAppearance()

        guard let presentation = HistoryEventPresentation.build(from: event) else {
            InternalFailurePresenter.log("Unable to build history event presentation for event type: \(event.type)")
            textLabel?.text = NSLocalizedString("No title", comment: "")
            detailTextLabel?.text = ""
            imageView?.image = PutioIcon.imageIcon.image(pointSize: 20)
            imageView?.tintColor = UIColor.Putio.Neutral.textSecondary
            return
        }

        textLabel?.text = presentation.text
        detailTextLabel?.text = presentation.detailText
        imageView?.image = presentation.icon.image(pointSize: 20)
        imageView?.tintColor = UIColor.Putio.Neutral.textSecondary
    }
}
