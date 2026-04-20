import UIKit
import PutioSDK
import AuthenticationServices

class LoginViewController: UIViewController, UITextFieldDelegate {
    var session: ASWebAuthenticationSession?

    @IBOutlet weak var loginButton: UIButton!
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    func authenticate(token: String) {
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.authenticate(token: token)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startWebAuthFlow()
    }

    @IBAction func loginButtonPressed(_ sender: Any) {
        startWebAuthFlow()
    }

    func startWebAuthFlow() {
        api.clearToken()
        
        let scheme = "putio"
        let url = api.getAuthURL(redirectURI: "\(scheme)://auth")

        session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
            self.handleWebAuthResult(callbackURL: callbackURL, error: error)
        }

        session?.presentationContextProvider = self
        session?.start()
    }

    func handleWebAuthResult(callbackURL: URL?, error: Error?) {
        if let error = error {
            return handleWebAuthCallbackFailure(error: error)
        }

        guard let callbackURL = callbackURL else {
            let error = NSError(
                domain: "",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The authentication session did not return a callback URL.", comment: "")]
            )
            return handleWebAuthCallbackFailure(error: error)
        }

        return handleWebAuthCallbackSuccess(callbackURL: callbackURL)
    }

    func handleWebAuthCallbackFailure(error: Error) {
        let alertController = UIAlertController(
            title: NSLocalizedString("Authentication failed", comment: ""),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        let closeButton = UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel, handler: nil)
        alertController.addAction(closeButton)
        present(alertController, animated: true, completion: nil)
    }

    // Callback URL: putio://auth#access_token={TOKEN}
    func handleWebAuthCallbackSuccess(callbackURL: URL) {
        var urlComponents = URLComponents()
        urlComponents.query = callbackURL.fragment

        guard let tokenFragment = urlComponents.queryItems?.first(where: { $0.name == "access_token" }), let token = tokenFragment.value else {
            let error = NSError(
                domain: "",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Missing access_token in the callback URL.", comment: "")]
            )
            return handleWebAuthCallbackFailure(error: error)
        }

        authenticate(token: token)
    }
}

extension LoginViewController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let window = view.window
            ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first else {
            preconditionFailure("Expected an application window for web authentication presentation")
        }

        return window
    }
}
