import UIKit
import PutioAPI

class SettingsTableViewCell: UITableViewCell {
    var item: SettingsModel.SectionItem?

    override func prepareForReuse() {
        super.prepareForReuse()
        self.accessoryView = UIView()
    }

    func configure(with item: SettingsModel.SectionItem) {
        self.item = item

        self.backgroundColor = UIColor.Putio.black
        self.imageView?.image = UIImage(named: item.icon)
        self.imageView?.tintColor = UIColor(red: 0.53, green: 0.53, blue: 0.53, alpha: 1.00)
        self.textLabel?.text = item.title

        switch item.type {
        case .text:
            if let text = item.value as? String {
                self.detailTextLabel?.text = text
            }

        case .button, .link:
            self.accessoryType = .disclosureIndicator
            self.accessoryView = UIImageView(image: UIImage(named: "chevronLeft")!)

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
