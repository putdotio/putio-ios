import UIKit
import Intercom
import PutioSDK

class DestroyAccounViewController: UIViewController {
    @IBAction func supportButtonTapped(_ sender: Any) {
        Intercom.present()
    }

    @IBAction func destroyButtonTapped(_ sender: Any) {
        let alertController = UIAlertController(
            title: NSLocalizedString("One last step", comment: ""),
            message: NSLocalizedString("Please enter your password for confirmation.", comment: ""),
            preferredStyle: .alert
        )

        let submitAction = UIAlertAction(title: NSLocalizedString("Destroy Account", comment: ""), style: .destructive) { [unowned alertController] _ in
            guard let password = alertController.textFields![0].text else { return }
            self.destroyAccount(password: password)
        }

        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: nil)

        alertController.addTextField { $0.isSecureTextEntry = true }
        alertController.addAction(submitAction)
        alertController.addAction(cancelAction)

        present(alertController, animated: true, completion: nil)
    }

    func destroyAccount(password: String) {
        let loadingAlert = UIAlertController(
            title: NSLocalizedString("Processing...", comment: ""),
            message: nil,
            preferredStyle: .alert
        )

        present(loadingAlert, animated: true) {
            api.destroyAccount(currentPassword: password) { result in
                loadingAlert.dismiss(animated: true) {
                    switch result {
                    case .success:
                        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
                        appDelegate.logout()

                    case .failure(let error):
                        self.destroyAccountFailure(error: error)
                    }
                }
            }
        }
    }

    func destroyAccountFailure(error: PutioSDKError) {
        let localizedError = api.localizeError(error: error, localizers: [
            APIErrorLocalizer(
                matcher: .errorType("INVALID_CURRENT_PASSWORD"),
                localize: { error in
                    return PutioLocalizedError(
                        message: NSLocalizedString("The password you entered doesn't match the one in our records", comment: ""),
                        recoverySuggestion: .instruction(description: NSLocalizedString("Please check your password and try again.", comment: "")),
                        underlyingError: error
                    )
            })
        ])

        let errorAlert = UIAlertController(title: localizedError.message, message: localizedError.recoverySuggestion.description, preferredStyle: .alert)
        errorAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel, handler: nil))

        present(errorAlert, animated: true, completion: nil)
    }
}
