import UIKit
import PutioSDK

class SettingsTableViewCell: UITableViewCell {
    var item: SettingsModel.SectionItem?

    override func prepareForReuse() {
        super.prepareForReuse()
        self.accessoryView = UIView()
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
                self.detailTextLabel?.text = text
            }

        case .button, .link:
            self.accessoryType = .disclosureIndicator
            let accessoryImageView = UIImageView(image: PutioIcon.caretRight.image)
            accessoryImageView.tintColor = UIColor.Putio.Yellow.solid
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
                self.accessoryView = switchView
            }
        }
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
