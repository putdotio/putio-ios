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
            guard error == nil, let callbackURL = callbackURL else { return }
            return self.handleWebAuthCallbackSuccess(callbackURL: callbackURL)
        }

        session?.presentationContextProvider = self
        session?.start()
    }

    func handleWebAuthCallbackFailure(error: Error) {
        let alertController = UIAlertController(title: "Authentication failed", message: error.localizedDescription, preferredStyle: .alert)
        let closeButton = UIAlertAction(title: "OK", style: .cancel, handler: nil)
        alertController.addAction(closeButton)
        present(alertController, animated: true, completion: nil)
    }

    // Callback URL: putio://auth#access_token={TOKEN}
    func handleWebAuthCallbackSuccess(callbackURL: URL) {
        var urlComponents = URLComponents()
        urlComponents.query = callbackURL.fragment

        guard let tokenFragment = urlComponents.queryItems?.first(where: { $0.name == "access_token" }), let token = tokenFragment.value else {
            let error = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing access_token in the callback URL."])
            return handleWebAuthCallbackFailure(error: error)
        }

        authenticate(token: token)
    }
}

extension LoginViewController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return view.window ?? ASPresentationAnchor()
    }
}
