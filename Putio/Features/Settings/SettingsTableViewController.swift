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
        navigationItem.title = NSLocalizedString("Account", comment: "")
    }

    func configureAppearance() {
        tableView.backgroundColor = UIColor.Putio.Surface.appBg
        tableView.contentInsetAdjustmentBehavior = .automatic

    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ProductAnalytics.capture(.screenViewed(.account))
        viewModel.fetchData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return viewModel.sections.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return viewModel.sections[section].title
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        GroupedSectionHeader.height(in: tableView)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return viewModel.sections[section].footer
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.sections[section].items.filter { $0.visible }.count
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        styleHeaderFooter(view)
    }

    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        styleHeaderFooter(view)
    }

    private func styleHeaderFooter(_ view: UIView) {
        guard let headerFooterView = view as? UITableViewHeaderFooterView else { return }
        headerFooterView.textLabel?.textColor = UIColor.Putio.Neutral.textSecondary
        // UIKit-created, so the nib font hook never reaches them.
        if let brandFont = BrandTypography.fontIfAvailable(.small) {
            headerFooterView.textLabel?.font = brandFont
            headerFooterView.textLabel?.adjustsFontForContentSizeCategory = true
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = viewModel.sections[indexPath.section].items.filter { $0.visible }[indexPath.row]

        if item.subtitle != nil {
            let cell = SettingsTableViewCell.dequeueSubtitleCell(from: tableView)
            cell.configure(with: item)
            return cell
        }

        guard let cell = tableView.dequeueReusableCell(withIdentifier: "settingsReuse", for: indexPath) as? SettingsTableViewCell else {
            InternalFailurePresenter.log("Unable to dequeue SettingsTableViewCell")
            return UITableViewCell()
        }

        cell.configure(with: item)
        return cell
    }

    func showPrivacyControls() {
        navigationController?.pushViewController(PrivacyControlsViewController(viewModel: viewModel), animated: true)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = viewModel.sections[indexPath.section].items.filter { $0.visible }[indexPath.row]
        guard let itemAction = item.action else { return }
        itemAction()
    }
}
