import UIKit
import PutioSDK

class LinkAccountViewController: UIViewController, UITextFieldDelegate {
    @IBOutlet weak var codeTextField: UITextField!

    override func viewDidLoad() {
        super.viewDidLoad()
        codeTextField.delegate = self
        codeTextField.becomeFirstResponder()
        // The device-link code is a machine-readable string, so type/show it in
        // the design system's code face. Font-only (keeps the field's size) and
        // a no-op when the licensed face is absent.
        if let codeFont = BrandTypography.fontIfAvailable(.code) {
            codeTextField.font = codeFont
        }
    }

    func link() {
        api.linkDevice(code: codeTextField.text!) { result in
            switch result {
            case .success(let connectedApp):
                let alert = UIAlertController(
                    title: NSLocalizedString("Connected!", comment: ""),
                    message: String(
                        format: NSLocalizedString("You have successfully linked to %@", comment: ""),
                        connectedApp.name
                    ),
                    preferredStyle: .alert
                )

                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel, handler: { (_) in
                    self.navigationController?.popViewController(animated: true)
                }))

                self.present(alert, animated: true, completion: nil)

            case .failure(let error):
                let alert = UIAlertController(
                    title: NSLocalizedString("Oops, an error occurred", comment: ""),
                    message: error.message,
                    preferredStyle: .alert
                )

                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel, handler: { (_) in
                    self.codeTextField.text = ""
                }))

                self.present(alert, animated: true, completion: nil)
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard !((textField.text?.isEmpty)!) else {
            return false
        }

        link()

        return true
    }
}
