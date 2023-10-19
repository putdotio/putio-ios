import UIKit
import PutioAPI

class LinkAccountViewController: UIViewController, UITextFieldDelegate {
    @IBOutlet weak var codeTextField: UITextField!

    override func viewDidLoad() {
        super.viewDidLoad()
        codeTextField.delegate = self
        codeTextField.becomeFirstResponder()
    }

    func link() {
        api.linkDevice(code: codeTextField.text!) { result in
            switch result {
            case .success(let connectedApp):
                let alert = UIAlertController(
                    title: "Connected!",
                    message: "You have successfully linked to \(connectedApp.name)",
                    preferredStyle: .alert
                )

                alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: { (_) in
                    self.navigationController?.popViewController(animated: true)
                }))

                self.present(alert, animated: true, completion: nil)

            case .failure(let error):
                let alert = UIAlertController(
                    title: "Oops, an error occurred 😢",
                    message: error.message,
                    preferredStyle: .alert
                )

                alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: { (_) in
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
