import UIKit

class ClearDataTableViewController: UITableViewController {
    let viewModel = ClearDataViewModel()

    @IBAction func cleanUpButtonPressed(_ sender: Any) {
        let loadingAlert = UIAlertController(
            title: NSLocalizedString("Cleaning up...", comment: ""),
            message: nil,
            preferredStyle: .alert
        )

        present(loadingAlert, animated: true) {
            self.viewModel.startCleanUp { result in
                loadingAlert.dismiss(animated: true) {
                    switch result {
                    case .failure(let error):
                        let localizedError = api.localizeError(error: error)
                        let errorAlert = UIAlertController(
                            title: localizedError.message,
                            message: localizedError.recoverySuggestion.description,
                            preferredStyle: .alert
                        )
                        errorAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel, handler: nil))
                        self.present(errorAlert, animated: true, completion: nil)

                    case .success:
                        let successAlert = UIAlertController(
                            title: NSLocalizedString("Done!", comment: ""),
                            message: nil,
                            preferredStyle: .alert
                        )

                        self.present(successAlert, animated: true, completion: {
                            successAlert.dismiss(animated: true, completion: {
                                self.navigationController?.popViewController(animated: true)
                            })
                        })
                    }
                }
            }
        }
    }

    // MARK: - Table view data source
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.options.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "clearDataReuse", for: indexPath)
        let key = viewModel.keys[indexPath.row]
        let value = viewModel.options[key] ?? false

        cell.textLabel?.text = key.split(separator: "_").map { $0 == "rss" ? $0.uppercased() : $0.localizedCapitalized }.joined(separator: " ")
        cell.accessoryType = value ? .checkmark : .none

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let key = viewModel.keys[indexPath.row]
        viewModel.toggleOption(key: key)
        tableView.reloadData()
    }
}
