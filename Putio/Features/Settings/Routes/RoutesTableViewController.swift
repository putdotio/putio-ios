import UIKit

class RoutesTableViewController: UITableViewController {
    var viewModel: RoutesViewModel = RoutesViewModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        tableView.refreshControl?.tintColor = UIColor.lightGray
        tableView.refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)

        viewModel.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        switch viewModel.state {
        case .idle:
            viewModel.fetchRoutes()
        default:
            break
        }
    }

    @objc func refresh() {
        viewModel.fetchRoutes()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.routes.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "RouteListCell", for: indexPath)
        let route = viewModel.routes[indexPath.row]

        cell.textLabel?.text = route.description
        cell.accessoryType = route.name == viewModel.getSelectedRouteName() ? .checkmark : .none

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let route = viewModel.routes[indexPath.row]

        viewModel.setRoute(route: route) { result in
            switch result {
            case .success:
                self.tableView.reloadData()

            case .failure(let error):
                let localizedError = api.localizeError(error: error)

                let errorAlert = UIAlertController(
                    title: localizedError.message,
                    message: localizedError.recoverySuggestion.description,
                    preferredStyle: .alert
                )

                errorAlert.addAction(UIAlertAction(title: "Close", style: .default, handler: nil))
                self.present(errorAlert, animated: true, completion: nil)
            }
        }
    }
}

extension RoutesTableViewController: RoutesViewModelDelegate {
    func stateChanged() {
        switch viewModel.state {
        case .success:
            tableView.refreshControl?.endRefreshing()
            tableView.reloadData()

        default:
            break
        }
    }
}
