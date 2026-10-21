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

/// Its own icon and labels rather than the built-in subtitle style, which
/// moves the detail line under the icon at larger text sizes.
class HistoryTableViewCell: UITableViewCell {
    // UIKit's subtitle-style metrics at the default text size, measured from
    // its rendering, so that size draws as it did; all grow with the text.
    private static let iconSize: CGFloat = 20
    private static let minimumHeight: CGFloat = 60
    private static let labelSpacing: CGFloat = 3
    private static let centerOffset: CGFloat = -5 / 6

    private let iconView = UIImageView()
    let titleLabel = UILabel()
    let detailLabel = UILabel()
    private var iconSizes: TextScaledSizes?
    private var minimumHeightConstraint: NSLayoutConstraint?
    private weak var labelsStack: UIStackView?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildLayout()
    }

    private func buildLayout() {
        // The storyboard prototype keeps the built-in style's placeholders.
        textLabel?.text = nil
        detailTextLabel?.text = nil
        imageView?.image = nil

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = UIColor.Putio.Neutral.textSecondary
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = UIColor.Putio.Neutral.text
        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.textColor = UIColor.Putio.Neutral.textSecondary
        for label in [titleLabel, detailLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.applyBrandFontIfAvailable()
        }

        let labels = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        labels.axis = .vertical
        labels.spacing = Self.labelSpacing
        labels.translatesAutoresizingMaskIntoConstraints = false
        labelsStack = labels

        contentView.addSubview(iconView)
        contentView.addSubview(labels)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -1 / 3),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 15),
            labels.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            labels.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: Self.centerOffset)
        ])
        let minimumHeight = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight)
        // Below required, so it yields to the table's own height while a row resizes.
        minimumHeight.priority = .required - 1
        minimumHeight.isActive = true
        minimumHeightConstraint = minimumHeight

        iconSizes = TextScaledSizes([iconView])
        scaleWithText()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: HistoryTableViewCell, _: UITraitCollection) in
            cell.scaleWithText()
        }
    }

    private func scaleWithText() {
        iconSizes?.apply(traitCollection)
        minimumHeightConstraint?.constant = TextScaledSizes.scaled(Self.minimumHeight, for: traitCollection)
        labelsStack?.spacing = TextScaledSizes.scaled(Self.labelSpacing, for: traitCollection)
    }

    func configure(with event: PutioHistoryEvent) {
        let presentation = HistoryEventPresentation.build(from: event)
        if presentation == nil {
            InternalFailurePresenter.log("Unable to build history event presentation for event type: \(event.type)")
        }
        titleLabel.text = presentation?.text ?? NSLocalizedString("No title", comment: "")
        detailLabel.text = presentation?.detailText ?? ""
        // One VoiceOver stop per row, as the built-in subtitle style gave.
        accessibilityLabel = [titleLabel.text, detailLabel.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        iconView.image = (presentation?.icon ?? .imageIcon).image
    }
}
