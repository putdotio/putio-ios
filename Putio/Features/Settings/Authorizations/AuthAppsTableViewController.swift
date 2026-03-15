import UIKit
import PutioAPI

class AuthAppsTableViewController: UITableViewController {
    var apps: [PutioOAuthGrant] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        configureApperance()
        fetchData()
    }

    func configureApperance() {
    }

    func fetchData() {
        api.getGrants { result in
            switch result {
            case .success(let apps):
                self.apps = apps
                self.tableView.reloadData()

            case .failure:
                break
            }
        }
    }

    // MARK: Swipe Actions
    func contextualDeleteAction(forRowAtIndexPath indexPath: IndexPath) -> UIContextualAction {
        let action = UIContextualAction(style: .destructive, title: "Revoke") { (_, _, handler) in
            api.revokeGrant(id: self.apps[indexPath.row].id) { result in
                switch result {
                case .success:
                    self.apps.remove(at: indexPath.row)
                    self.tableView.deleteRows(at: [indexPath], with: .automatic)
                    handler(true)

                case .failure:
                    handler(false)
                }
            }
        }

        action.backgroundColor = .systemRed

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
        let actions = [contextualDeleteAction(forRowAtIndexPath: indexPath)]
        return UISwipeActionsConfiguration(actions: actions)
    }
}
