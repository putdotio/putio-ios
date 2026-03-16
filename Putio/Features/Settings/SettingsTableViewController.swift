import UIKit
import Intercom
import NotificationCenter

class SettingsTableViewController: UITableViewController, TwoFactorAuthPresenter {
    var viewModel: SettingsViewModel = SettingsViewModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.tableViewController = self
        configureAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.title = "Account"
    }

    func configureAppearance() {
        tableView.backgroundColor = UIColor.Putio.background
        tableView.contentInsetAdjustmentBehavior = .automatic

    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        viewModel.fetchData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return viewModel.sections.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return viewModel.sections[section].title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.sections[section].items.filter { $0.visible }.count
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let headerView = view as? UITableViewHeaderFooterView else { return }
        headerView.textLabel?.textColor = UIColor.Putio.listSubtitle
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "settingsReuse", for: indexPath) as! SettingsTableViewCell
        let item = viewModel.sections[indexPath.section].items.filter { $0.visible }[indexPath.row]
        cell.configure(with: item)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = viewModel.sections[indexPath.section].items.filter { $0.visible }[indexPath.row]
        guard let itemAction = item.action else { return }
        itemAction()
    }
}
