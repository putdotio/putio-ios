import UIKit
import PutioSDK
import AuthenticationServices

final class WebAuthAutoStart {
    static let shared = WebAuthAutoStart()

    private var isSpent = false

    func claim(failure: LoginFailure?, isMockAPIEnabled: Bool) -> Bool {
        defer { isSpent = true }
        return !isSpent && failure == nil && !isMockAPIEnabled
    }
}

class LoginViewController: UIViewController, UITextFieldDelegate {
    var session: ASWebAuthenticationSession?
    var currentOAuthState: String?
    var failure: LoginFailure?
    var webAuthAutoStart = WebAuthAutoStart.shared

    @IBOutlet weak var loginButton: UIButton!
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    func authenticate(token: String) {
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.authenticate(token: token)
        }
    }
    
    func retrySessionLoad() {
        loginButton?.isEnabled = false
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.retrySessionLoad()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        let failure = failure
        self.failure = nil

        // Web auth cannot complete against the mocked API, and its system
        // consent alert would sit above the whole simulator until dismissed,
        // stranding any test that landed here. Tapping "Log in" still starts it.
        if webAuthAutoStart.claim(failure: failure, isMockAPIEnabled: PutioE2EEnvironment.isMockAPIEnabled) {
            return startWebAuthFlow()
        }

        if let failure {
            presentFailure(failure)
        }
    }

    func presentFailure(_ failure: LoginFailure) {
        let alertController: UIAlertController
        switch failure {
        case .sessionExpired:
            alertController = UIAlertController(
                title: NSLocalizedString("Session expired", comment: ""),
                message: NSLocalizedString("Log in again to continue.", comment: ""),
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Log in", comment: ""), style: .default) { [weak self] _ in
                self?.startWebAuthFlow()
            })
        case .sessionLoad:
            alertController = UIAlertController(
                title: NSLocalizedString("Couldn't load your account", comment: ""),
                message: NSLocalizedString("Try again in a moment.", comment: ""),
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Retry", comment: ""), style: .default) { [weak self] _ in
                self?.retrySessionLoad()
            })
        }
        alertController.preferredAction = alertController.actions.first
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: nil))
        present(alertController, animated: true, completion: nil)
    }

    @IBAction func loginButtonPressed(_ sender: Any) {
        startWebAuthFlow()
    }

    func startWebAuthFlow() {
        api.clearToken()
        
        let scheme = "putio"
        let state = UUID().uuidString
        currentOAuthState = state
        let url = api.getAuthURL(redirectURI: "\(scheme)://auth", state: state)

        session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
            self.handleWebAuthResult(callbackURL: callbackURL, error: error)
        }

        session?.presentationContextProvider = self
        session?.start()
    }

    func handleWebAuthResult(callbackURL: URL?, error: Error?) {
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            currentOAuthState = nil
            return
        }

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
        currentOAuthState = nil

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
        defer { currentOAuthState = nil }

        guard callbackURL.scheme == "putio",
              callbackURL.host == "auth",
              callbackURL.path.isEmpty || callbackURL.path == "/" else {
            let error = NSError(
                domain: "",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Unexpected authentication callback URL.", comment: "")]
            )
            return handleWebAuthCallbackFailure(error: error)
        }

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

        guard let returnedState = urlComponents.queryItems?.first(where: { $0.name == "state" })?.value,
              returnedState == currentOAuthState else {
            let error = NSError(
                domain: "",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Authentication state did not match the current session.", comment: "")]
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
