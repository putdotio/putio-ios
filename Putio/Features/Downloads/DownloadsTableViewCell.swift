import UIKit
import PutioSDK
import RealmSwift

protocol DownloadsTableViewCellDelegate: AnyObject {
    func downloadCellActionButtonTapped(download: Download, sender: DownloadsTableViewCell)
}

class DownloadsTableViewCell: UITableViewCell {
    weak var delegate: DownloadsTableViewCellDelegate?

    lazy var realm: Realm? = PutioRealm.open(context: "DownloadsTableViewCell.realm")
    var id: Int?
    private var standardAccessibilityHint: String?

    @IBOutlet weak var icon: UIImageView!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var subtitleLabel: UILabel!
    @IBOutlet weak var labelContainer: UIView!
    @IBOutlet weak var labelsStack: UIStackView!
    @IBOutlet weak var downloadButtonContainer: UIView!

    private lazy var stateButton: DownloadStateButton = {
        let button = DownloadStateButton()
        button.addTarget(self, action: #selector(downloadButtonTapped(_:)), for: .touchUpInside)
        return button
    }()

    override func awakeFromNib() {
        super.awakeFromNib()

        stateButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButtonContainer.addSubview(stateButton)
        NSLayoutConstraint.activate([
            stateButton.topAnchor.constraint(equalTo: downloadButtonContainer.topAnchor),
            stateButton.bottomAnchor.constraint(equalTo: downloadButtonContainer.bottomAnchor),
            stateButton.leadingAnchor.constraint(equalTo: downloadButtonContainer.leadingAnchor),
            stateButton.trailingAnchor.constraint(equalTo: downloadButtonContainer.trailingAnchor),
            labelContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            labelsStack.topAnchor.constraint(greaterThanOrEqualTo: labelContainer.topAnchor, constant: 8),
            labelsStack.bottomAnchor.constraint(lessThanOrEqualTo: labelContainer.bottomAnchor, constant: -8)
        ])
    }

    @IBAction func downloadButtonTapped(_ sender: Any) {
        guard let realm,
              let id,
              let download = realm.object(ofType: Download.self, forPrimaryKey: id) else {
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
        accessibilityIdentifier = nil
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        standardAccessibilityHint = nil
        accessibilityTraits.remove([.button, .selected, .notEnabled])
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        downloadButtonContainer.isHidden = editing
    }

    func configure(with downloadId: Int) {
        guard let realm,
              let download = realm.object(ofType: Download.self, forPrimaryKey: downloadId) else {
            return log.error(["configure failed", id as Any, downloadId])
        }

        id = download.id
        standardAccessibilityHint = accessibilityActionHint(for: download.state)
        accessibilityIdentifier = "putio-download-\(download.id)"
        titleLabel?.text = download.name
        icon.image = download.fileType == .video ? PutioIcon.fileVideo.image : PutioIcon.fileAudio.image
        icon.tintColor = UIColor.Putio.Neutral.textSecondary
        selectionStyle = .none
        downloadButtonContainer.isHidden = isEditing

        guard download.state == .completed else {
            switch download.state {
            case .queued:
                stateButton.displayState = .queued
                subtitleLabel?.text = NSLocalizedString("In Queue", comment: "")
            case .starting:
                stateButton.displayState = .progress(0)
                subtitleLabel?.text = NSLocalizedString("Starting...", comment: "")
            case .active:
                let progress = DownloadProgressPresentation.fraction(from: download.progress)
                stateButton.displayState = .progress(CGFloat(progress))
                subtitleLabel?.text = DownloadProgressPresentation.activeStatus(
                    fraction: progress
                )
            case .stopped:
                stateButton.displayState = .idle
                subtitleLabel?.text = NSLocalizedString("Stopped", comment: "")
            case .failed:
                stateButton.displayState = .idle
                subtitleLabel?.text = String(
                    format: NSLocalizedString("Failed: %@", comment: ""),
                    download.message
                )
            case .completed:
                break
            }

            configureStandardAccessibility()
            return
        }

        let completedAtText = download.completedAt?.timeAgoSinceDate() ?? NSLocalizedString("recently", comment: "")
        subtitleLabel?.text = String(
            format: NSLocalizedString("%@ - Downloaded %@", comment: ""),
            download.size.bytesToHumanReadable(),
            completedAtText
        )
        icon.image = download.fileType == .video ? PutioIcon.fileVideo.image : PutioIcon.fileAudio.image
        icon.tintColor = UIColor.Putio.Yellow.solid
        stateButton.displayState = .completed
        selectionStyle = .default
        configureStandardAccessibility()
    }

    override func accessibilityActivate() -> Bool {
        guard !isEditing, delegate != nil else { return super.accessibilityActivate() }
        downloadButtonTapped(self)
        return true
    }

    private func configureStandardAccessibility() {
        isAccessibilityElement = true
        accessibilityLabel = [titleLabel.text, subtitleLabel.text]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        accessibilityValue = nil
        accessibilityHint = standardAccessibilityHint
        accessibilityTraits.remove([.selected, .notEnabled])
        accessibilityTraits.insert(.button)
    }

    private func accessibilityActionHint(for state: Download.State) -> String {
        switch state {
        case .queued, .starting, .active:
            return NSLocalizedString("Double tap to stop this download.", comment: "")
        case .stopped, .failed:
            return NSLocalizedString("Double tap to retry this download.", comment: "")
        case .completed:
            return NSLocalizedString("Double tap to open this download.", comment: "")
        }
    }

    func configureSelectionAccessibility(
        isSelecting: Bool,
        isSelected: Bool,
        isSelectable: Bool
    ) {
        guard isSelecting else {
            configureStandardAccessibility()
            return
        }

        isAccessibilityElement = true
        accessibilityTraits.remove(.button)

        if isSelectable {
            accessibilityLabel = [titleLabel.text, subtitleLabel.text]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            accessibilityTraits.remove(.notEnabled)
            accessibilityValue = isSelected
                ? NSLocalizedString("Selected", comment: "")
                : NSLocalizedString("Not selected", comment: "")
            accessibilityHint = isSelected
                ? NSLocalizedString("Double tap to deselect this download.", comment: "")
                : NSLocalizedString("Double tap to select this download.", comment: "")

            if isSelected {
                accessibilityTraits.insert(.selected)
            } else {
                accessibilityTraits.remove(.selected)
            }
        } else {
            accessibilityLabel = titleLabel.text
            accessibilityValue = subtitleLabel.text
            accessibilityHint = NSLocalizedString("Only completed downloads can be selected.", comment: "")
            accessibilityTraits.remove(.selected)
            accessibilityTraits.insert(.notEnabled)
        }
    }
}

enum DownloadProgressPresentation {
    static func fraction(from persistedValue: String) -> Double {
        guard let fraction = Double(persistedValue), fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    static func percentage(
        fraction: Double,
        locale: Locale = .current
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfUp

        let clamped = min(max(fraction, 0), 1)
        return formatter.string(from: NSNumber(value: clamped)) ?? "0%"
    }

    static func activeStatus(
        fraction: Double,
        locale: Locale = .current
    ) -> String {
        String(
            format: NSLocalizedString("Downloading... %@", comment: ""),
            percentage(fraction: fraction, locale: locale)
        )
    }
}

// MARK: - Download State Button

class DownloadStateButton: UIControl {
    enum DisplayState: Equatable {
        case idle
        case queued
        case progress(CGFloat)
        case completed
    }

    var displayState: DisplayState = .idle {
        didSet { update(from: oldValue) }
    }

    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let iconView = UIImageView()
    private var iconSizeConstraints = [NSLayoutConstraint]()

    private let gray = UIColor.Putio.Neutral.solid

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear

        trackLayer.fillColor = nil
        trackLayer.lineWidth = 2
        trackLayer.lineCap = .round

        progressLayer.fillColor = nil
        progressLayer.lineWidth = 2
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0

        resolveLayerColors()

        layer.addSublayer(trackLayer)
        layer.addSublayer(progressLayer)

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = gray
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        iconSizeConstraints = [
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20)
        ]
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ] + iconSizeConstraints)

        update(from: nil)
    }

    // CALayer colors don't track appearance changes; re-resolve on trait change.
    private func resolveLayerColors() {
        trackLayer.strokeColor = UIColor.Putio.Neutral.line.resolvedColor(with: traitCollection).cgColor
        progressLayer.strokeColor = UIColor.Putio.Yellow.solid.resolvedColor(with: traitCollection).cgColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            resolveLayerColors()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 10
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = UIBezierPath(
            arcCenter: CGPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        )
        trackLayer.path = path.cgPath
        progressLayer.path = path.cgPath
    }

    private func setIconSize(_ size: CGFloat) {
        iconSizeConstraints.forEach { $0.constant = size }
    }

    private func update(from oldValue: DisplayState?) {
        switch displayState {
        case .idle:
            trackLayer.isHidden = true
            progressLayer.isHidden = true
            setIconSize(20)
            iconView.image = PutioIcon.downloadSimple.image(pointSize: 20)
            iconView.tintColor = gray

        case .queued:
            trackLayer.isHidden = true
            progressLayer.isHidden = true
            setIconSize(20)
            iconView.image = PutioIcon.clock.image(pointSize: 20)
            iconView.tintColor = gray

        case .progress(let value):
            trackLayer.isHidden = false
            progressLayer.isHidden = false
            setIconSize(14)
            iconView.image = PutioIcon.stopFill.image(pointSize: 14)
            iconView.tintColor = gray

            let clamped = min(max(value, 0), 1)
            if case .progress = oldValue {
                let anim = CABasicAnimation(keyPath: "strokeEnd")
                anim.fromValue = progressLayer.presentation()?.strokeEnd ?? progressLayer.strokeEnd
                anim.toValue = clamped
                anim.duration = 0.3
                anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                progressLayer.strokeEnd = clamped
                progressLayer.add(anim, forKey: "progress")
            } else {
                progressLayer.removeAllAnimations()
                progressLayer.strokeEnd = clamped
            }

        case .completed:
            trackLayer.isHidden = true
            progressLayer.isHidden = true
            setIconSize(20)
            iconView.image = PutioIcon.checkCircleFill.image(pointSize: 20)
            iconView.tintColor = UIColor.Putio.Yellow.solid
        }
    }
}
