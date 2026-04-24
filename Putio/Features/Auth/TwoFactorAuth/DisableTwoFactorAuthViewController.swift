import UIKit
import PutioSDK

class DisableTwoFactorAuthViewController: UIViewController {
    @IBOutlet weak var textField: UITextField!
    @IBOutlet weak var button: Button!

    override func viewDidLoad() {
        super.viewDidLoad()
        textField.delegate = self
        textField.becomeFirstResponder()
    }

    func handleSubmit(code: String) {
        let loadingAlert = UIAlertController(
            title: NSLocalizedString("Disabling...", comment: ""),
            message: "",
            preferredStyle: .alert
        )

        self.present(loadingAlert, animated: true, completion: nil)

        api.saveAccountSettings(.twoFactor(PutioTwoFactorSettings(code: code, enable: false))) { result in
            loadingAlert.dismiss(animated: true) {
                switch result {
                case .success:
                    if let realm = PutioRealm.open(context: "DisableTwoFactorAuthViewController.handleSubmit"),
                        let settings = realm.objects(User.self).first?.settings {
                        _ = PutioRealm.write(realm, context: "DisableTwoFactorAuthViewController.handleSubmit") {
                            settings.twoFactorEnabled = false
                        }
                    }

                    self.dismiss(animated: true)

                case .failure(let error):
                    let localizedError = AuthErrors.localizeTwoFactorAuthError(error: error)

                    let errorAlert = UIAlertController(
                        title: localizedError.message,
                        message: localizedError.recoverySuggestion.description,
                        preferredStyle: .alert
                    )
                    errorAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel, handler: nil))

                    return self.present(errorAlert, animated: true, completion: nil)
                }
            }
        }
    }

    @IBAction func onDismiss(_ sender: Any) {
        self.dismiss(animated: true)
    }

    @IBAction func onDisable(_ sender: Any) {
        guard !((textField.text?.isEmpty)!), let code = textField.text else { return }
        handleSubmit(code: code)
    }
}

extension DisableTwoFactorAuthViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard !((textField.text?.isEmpty)!), let code = textField.text else { return false }
        handleSubmit(code: code)
        return true
    }
}
