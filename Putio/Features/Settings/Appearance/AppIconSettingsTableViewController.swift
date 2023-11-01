import UIKit

class AppIconSettingsTableViewController: UITableViewController {
    struct AppIcon {
        let name: String
        let title: String
        let fileName: String
    }

    let icons: [AppIcon] = [
        AppIcon(name: "AppIconRetro", title: "Retro", fileName: "appIconRetro"),
        AppIcon(name: "AppIconRainbow", title: "Rainbow", fileName: "appIconRainbow")
    ]

    lazy var selectedIconName: String = {
        return UIApplication.shared.alternateIconName ?? self.icons[0].name
    }()

    // MARK: - Table view data source
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return icons.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "appIconSettingsReuse", for: indexPath)
        let icon = icons[indexPath.row]

        cell.imageView?.image = UIImage(named: icon.fileName)
        cell.textLabel?.text = icon.title

        if selectedIconName == icon.name {
            cell.accessoryType = .checkmark
        } else {
            cell.accessoryType = .none
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let icon = icons[indexPath.row]
        let iconName = icon.name == icons[0].name ? nil : icon.name

        UIApplication.shared.setAlternateIconName(iconName, completionHandler: { _ in
            self.selectedIconName = icon.name
            self.tableView.reloadData()
        })
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 55.0
    }
}
