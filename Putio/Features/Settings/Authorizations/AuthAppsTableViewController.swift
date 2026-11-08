import UIKit
import PutioSDK

class AuthAppsTableViewController: UITableViewController {
    var apps: [PutioOAuthGrant] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        configureApperance()
        fetchData()
    }

    func configureApperance() {
    }

    func presentAuthAppsError(_ error: PutioErrorLocalizableInput) {
        let localizedError = api.localizeError(error: error)
        let errorAlert = UIAlertController(
            title: localizedError.message,
            message: localizedError.recoverySuggestion.description,
            preferredStyle: .alert
        )
        errorAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel))
        present(errorAlert, animated: true)
    }

    func fetchData() {
        api.getGrants { result in
            switch result {
            case .success(let apps):
                self.apps = apps
                self.tableView.reloadData()

            case .failure(let error):
                self.presentAuthAppsError(error)
            }
        }
    }

    // MARK: Swipe Actions
    func contextualDeleteAction(forGrantID grantID: Int) -> UIContextualAction {
        let action = UIContextualAction(
            style: .destructive,
            title: NSLocalizedString("Revoke", comment: "")
        ) { (_, _, handler) in
            api.revokeGrant(id: grantID) { result in
                switch result {
                case .success:
                    let removal = AuthAppsList.removingGrant(id: grantID, from: self.apps)
                    guard let row = removal.removedIndex else {
                        handler(false)
                        return
                    }

                    self.apps = removal.apps
                    self.tableView.deleteRows(at: [IndexPath(row: row, section: 0)], with: .automatic)
                    handler(true)

                case .failure(let error):
                    self.presentAuthAppsError(error)
                    handler(false)
                }
            }
        }

        action.backgroundColor = UIColor.Putio.Red.solid

        return action
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return apps.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let app = apps[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "AuthAppsListCell", for: indexPath)

        cell.textLabel?.text = app.name
        cell.detailTextLabel?.text = app.description

        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return String(apps[indexPath.row].id) != PUTIOKIT_CLIENT_ID
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let actions = [contextualDeleteAction(forGrantID: apps[indexPath.row].id)]
        return UISwipeActionsConfiguration(actions: actions)
    }
}
