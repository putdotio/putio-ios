import UIKit

class EnableTwoFactorCodeViewController: UIViewController {
    @IBOutlet weak var textField: UITextField!
    @IBOutlet weak var button: Button!

    override func viewDidLoad() {
        super.viewDidLoad()
        textField.delegate = self
        textField.becomeFirstResponder()
    }

    func handleSubmit(code: String) {
        let loadingAlert = UIAlertController(
            title: "Enabling...",
            message: "",
            preferredStyle: .alert
        )

        self.present(loadingAlert, animated: true, completion: nil)

        api.saveAccountSettings(body: ["two_factor_enabled": ["enable": true, "code": code]]) { result in
            loadingAlert.dismiss(animated: true) {
                switch result {
                case .success:
                    if let realm = PutioRealm.open(context: "EnableTwoFactorCodeViewController.handleSubmit"),
                        let settings = realm.objects(User.self).first?.settings {
                        _ = PutioRealm.write(realm, context: "EnableTwoFactorCodeViewController.handleSubmit") {
                            settings.twoFactorEnabled = true
                        }
                    }

                    self.performSegue(withIdentifier: "toTwoFactorRecoveryCodesVC", sender: nil)

                case .failure(let error):
                    let localizedError = AuthErrors.localizeTwoFactorAuthError(error: error)

                    let errorAlert = UIAlertController(
                        title: localizedError.message,
                        message: localizedError.recoverySuggestion.description,
                        preferredStyle: .alert
                    )
                    errorAlert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))

                    return self.present(errorAlert, animated: true, completion: nil)
                }
            }
        }
    }

    @IBAction func enableButtonTapped(_ sender: Any) {
        guard !((textField.text?.isEmpty)!), let code = textField.text else { return }
        handleSubmit(code: code)
    }
}

extension EnableTwoFactorCodeViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard !((textField.text?.isEmpty)!), let code = textField.text else { return false }
        handleSubmit(code: code)
        return true
    }
}
