import UIKit
import PutioSDK
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
            stateButton.trailingAnchor.constraint(equalTo: downloadButtonContainer.trailingAnchor)
        ])
    }

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
            switch download.state {
            case .queued:
                stateButton.displayState = .queued
                subtitleLabel?.text = "In Queue"
            case .starting:
                stateButton.displayState = .progress(0)
                subtitleLabel?.text = "Starting..."
            case .active:
                stateButton.displayState = .progress(CGFloat((download.progress as NSString).floatValue))
                subtitleLabel?.text = "Downloading..."
            case .stopped:
                stateButton.displayState = .idle
                subtitleLabel?.text = "Stopped"
            case .failed:
                stateButton.displayState = .idle
                subtitleLabel?.text = "Failed: \(download.message)"
            case .completed:
                break
            }

            return
        }

        subtitleLabel?.text = "\(download.size.bytesToHumanReadable()) - Downloaded \(download.completedAt!.timeAgoSinceDate())"
        icon.image = download.fileType == .video ? UIImage.Putio.video : UIImage.Putio.audio
        stateButton.displayState = .completed
        selectionStyle = .default
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

    private let gray = UIColor(white: 0.5, alpha: 1)

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
        trackLayer.strokeColor = UIColor(white: 0.25, alpha: 1).cgColor
        trackLayer.lineWidth = 2
        trackLayer.lineCap = .round

        progressLayer.fillColor = nil
        progressLayer.strokeColor = UIColor.Putio.yellow.cgColor
        progressLayer.lineWidth = 2
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0

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
            iconView.image = UIImage(systemName: "arrow.down.circle")
            iconView.tintColor = gray

        case .queued:
            trackLayer.isHidden = true
            progressLayer.isHidden = true
            setIconSize(20)
            iconView.image = UIImage(systemName: "clock")
            iconView.tintColor = gray

        case .progress(let value):
            trackLayer.isHidden = false
            progressLayer.isHidden = false
            setIconSize(14)
            iconView.image = UIImage(systemName: "stop.fill")
            iconView.tintColor = gray

            let clamped = min(max(value, 0), 1)
            if case .progress = oldValue {
                // Animate from current position
                let anim = CABasicAnimation(keyPath: "strokeEnd")
                anim.fromValue = progressLayer.presentation()?.strokeEnd ?? progressLayer.strokeEnd
                anim.toValue = clamped
                anim.duration = 0.3
                anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                progressLayer.strokeEnd = clamped
                progressLayer.add(anim, forKey: "progress")
            } else {
                // First progress update - set directly
                progressLayer.removeAllAnimations()
                progressLayer.strokeEnd = clamped
            }

        case .completed:
            trackLayer.isHidden = true
            progressLayer.isHidden = true
            setIconSize(20)
            iconView.image = UIImage(systemName: "checkmark.circle.fill")
            iconView.tintColor = UIColor.Putio.yellow
        }
    }
}
