import UIKit

class ClearDataTableViewController: UITableViewController {
    let viewModel = ClearDataViewModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "putio-clear-data-table"
        navigationItem.rightBarButtonItem?.isEnabled = viewModel.canClear
    }

    @IBAction func cleanUpButtonPressed(_ sender: Any) {
        let loadingAlert = UIAlertController(
            title: NSLocalizedString("Cleaning up...", comment: ""),
            message: nil,
            preferredStyle: .alert
        )

        viewModel.cleanUp(confirm: { message, answer in
            let confirmation = UIAlertController(
                title: NSLocalizedString("Clear the selected data?", comment: ""),
                message: message,
                preferredStyle: .alert
            )
            confirmation.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                answer(false)
            })
            confirmation.addAction(UIAlertAction(title: NSLocalizedString("Clear", comment: ""), style: .destructive) { _ in
                self.present(loadingAlert, animated: true) {
                    answer(true)
                }
            })
            self.present(confirmation, animated: true)
        }, completion: { result in
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
        })
    }

    // MARK: - Table view data source
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.options.count
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        var content = UIListContentConfiguration.header()
        content.text = NSLocalizedString(
            "These permanently delete data from your put.io account, on every device. To free up space on this device, delete downloads in Downloads instead.",
            comment: ""
        )
        content.textProperties.color = UIColor.Putio.Neutral.textSecondary
        content.directionalLayoutMargins.leading = tableView.separatorInset.left
        // UIKit-created, so the nib font hook never reaches it.
        if let brandFont = BrandTypography.fontIfAvailable(.small) {
            content.textProperties.font = brandFont
            content.textProperties.adjustsFontForContentSizeCategory = true
        }

        var background = UIBackgroundConfiguration.listHeader()
        background.backgroundColor = UIColor.Putio.Surface.appBg

        let header = UITableViewHeaderFooterView()
        header.contentConfiguration = content
        header.backgroundConfiguration = background
        return header
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "clearDataReuse", for: indexPath)
        let key = viewModel.keys[indexPath.row]
        let value = viewModel.options[key] ?? false

        cell.textLabel?.text = viewModel.title(for: key)
        cell.accessoryType = value ? .checkmark : .none

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let key = viewModel.keys[indexPath.row]
        viewModel.toggleOption(key: key)
        navigationItem.rightBarButtonItem?.isEnabled = viewModel.canClear
        tableView.reloadData()
    }
}
