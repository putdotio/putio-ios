import UIKit

/// The inactive-account banner above the signed-in tabs. It only informs, so
/// nothing in it is tappable, and VoiceOver reads it as one element. It
/// reaches under the status bar and keeps its text inside the safe area.
final class AccountNoticeView: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    func configure(with notice: AccountNotice?, now: Date = Date()) {
        isHidden = notice == nil
        guard let notice else {
            accessibilityLabel = nil
            return
        }

        let message = notice.message(now: now)
        titleLabel.text = notice.title
        messageLabel.text = message
        messageLabel.isHidden = message == nil
        accessibilityLabel = [notice.title, message].compactMap { $0 }.joined(separator: ", ")
    }

    private func setUp() {
        backgroundColor = UIColor.Putio.Yellow.componentBg
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityIdentifier = "putio-account-notice"

        iconView.image = PutioIcon.warningCircle.image(pointSize: 20)
        iconView.tintColor = UIColor.Putio.Yellow.textSecondary

        // Text stops growing at the first accessibility size, so a persistent
        // banner never crowds out the screen under it. VoiceOver and the
        // playback alert still carry the full notice.
        maximumContentSizeCategory = .accessibilityMedium

        titleLabel.font = BrandTypography.fontIfAvailable(.body) ?? .preferredFont(forTextStyle: .body)
        titleLabel.textColor = UIColor.Putio.Yellow.text
        messageLabel.font = BrandTypography.fontIfAvailable(.small) ?? .preferredFont(forTextStyle: .footnote)
        messageLabel.textColor = UIColor.Putio.Fg.foreground
        for label in [titleLabel, messageLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }

        let textStack = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        textStack.axis = .vertical
        textStack.spacing = 4

        let row = UIStackView(arrangedSubviews: [iconView, textStack])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let border = UIView()
        border.backgroundColor = UIColor.Putio.Yellow.border
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            row.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: border.topAnchor, constant: -12),

            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1)
        ])
    }
}
