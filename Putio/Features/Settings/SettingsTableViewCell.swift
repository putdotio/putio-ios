import UIKit
import PutioSDK

class SettingsTableViewCell: UITableViewCell {
    static let subtitleReuseIdentifier = "settingsSubtitleReuse"

    var item: SettingsModel.SectionItem?

    /// A code-built cell in the subtitle style, for rows whose description
    /// sits under the title. The storyboard prototype is right-detail only.
    static func dequeueSubtitleCell(from tableView: UITableView) -> SettingsTableViewCell {
        if let cell = tableView.dequeueReusableCell(withIdentifier: subtitleReuseIdentifier) as? SettingsTableViewCell {
            return cell
        }
        let cell = SettingsTableViewCell(style: .subtitle, reuseIdentifier: subtitleReuseIdentifier)
        cell.selectionStyle = .none
        cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        return cell
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.accessoryView = UIView()
        self.accessibilityValue = nil
    }

    func configure(with item: SettingsModel.SectionItem) {
        self.item = item

        self.backgroundColor = UIColor.Putio.Neutral.componentBg
        self.imageView?.image = item.icon.image(for: .navigationList)
        self.imageView?.contentMode = .center
        self.imageView?.tintColor = UIColor.Putio.Neutral.textSecondary
        self.textLabel?.text = item.title

        switch item.type {
        case .text:
            if let text = item.value as? String {
                if item.subtitle == nil {
                    self.detailTextLabel?.text = text
                } else {
                    self.accessoryView = valueLabel(text)
                    self.accessibilityValue = text
                }
            }

        case .button, .link:
            self.accessoryType = .disclosureIndicator
            let accessoryImageView = UIImageView(image: PutioIcon.caretRight.image)
            accessoryImageView.tintColor = UIColor.Putio.Yellow.textSecondary
            self.accessoryView = accessoryImageView

            if let text = item.value as? String {
                self.detailTextLabel?.text = text
            }

        case .toggle:
            self.detailTextLabel?.text = ""

            if let value = item.value as? Bool {
                let switchView = UISwitch(frame: .zero)
                switchView.isOn = value
                switchView.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
                // The description belongs to the control, not only to the
                // text beside it, so VoiceOver reads it on the switch.
                switchView.accessibilityLabel = item.title
                switchView.accessibilityHint = item.subtitle
                self.accessoryView = switchView
            }
        }

        if let subtitle = item.subtitle {
            self.detailTextLabel?.text = subtitle
        }

        if reuseIdentifier == Self.subtitleReuseIdentifier {
            // An empty second line would still push the title off centre.
            if detailTextLabel?.text?.isEmpty == true {
                detailTextLabel?.text = nil
            }
            configureGlobalAppearance()
        }
    }

    private func valueLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.preferredFont(forTextStyle: .callout)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.Putio.Neutral.textSecondary
        label.applyBrandFontIfAvailable()
        label.sizeToFit()
        return label
    }

    @objc func switchChanged(_ sender: UISwitch!) {
        guard let item = self.item else { return }
        guard item.type == .toggle, let action = item.action else { return }

        if let value = item.value as? Bool {
            sender.setOn(value, animated: true)
        }

        action()
    }
}
