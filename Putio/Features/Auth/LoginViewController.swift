import UIKit
import PutioAPI
import AuthenticationServices

class LoginViewController: UIViewController, UITextFieldDelegate {
    var session: ASWebAuthenticationSession?

    @IBOutlet weak var usernameField: UITextField!
    @IBOutlet weak var passwordField: UITextField!
    @IBOutlet weak var loginButton: UIButton!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet weak var alternativeLoginMethodButton: UIButton!

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        usernameField.delegate = self
        passwordField.delegate = self
        configureAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    func configureAppearance() {
        let fields: [UITextField] = [usernameField, passwordField]

        loginButton.isEnabled = false
        usernameField.becomeFirstResponder()

        fields.forEach {
            $0.tintColor = UIColor.lightGray
            $0.textColor = UIColor.white
            $0.backgroundColor = UIColor.Putio.black
            $0.borderStyle = UITextBorderStyle.roundedRect
        }

        setLoginButtonState()
        alternativeLoginMethodButton.setTitle("Having trouble? Try logging in with browser →", for: .normal)
    }

    func authenticate(token: String) {
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.authenticate(token: token)
        }
    }

    func login() {
        setLoginButtonState(isBusy: true)

        api.clearToken()
        api.login(username: usernameField.text!, password: passwordField.text!) { result in
            switch result {
            case .success(let token):
                self.loginSuccess(token: token)

            case .failure(let error):
                self.loginFailure(error: error)
            }
        }
    }

    func loginSuccess(token: String) {
        self.validateToken(token: token)
    }

    func loginFailure(error: PutioAPIError) {
        self.setLoginButtonState(isBusy: false)
        let localizedError = AuthErrors.localizeLoginError(error: error)
        let alert = UIAlertController(title: localizedError.message, message: localizedError.recoverySuggestion.description, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
        return self.present(alert, animated: true, completion: nil)
    }

    func validateToken(token: String) {
        api.setToken(token: token)
        api.validateToken(token: token) { result in
            switch result {
            case .success(let validationResult):
                self.validateTokenSuccess(token: token, validationResult: validationResult)

            case .failure(let error):
                self.validateTokenFailure(error: error)
            }
        }
    }

    func validateTokenSuccess(token: String, validationResult: PutioTokenValidationResult) {
        guard validationResult.token_scope == "two_factor" else {
            return self.authenticate(token: token)
        }

        return self.presentOTPInput()
    }

    func validateTokenFailure(error: PutioAPIError) {
        self.loginFailure(error: error)
    }

    func presentOTPInput() {
        let alertController = UIAlertController(
            title: "Two-factor authentication",
            message: "Please enter the access code from your authenticator or one of your recovery codes.",
            preferredStyle: .alert
        )

        alertController.addTextField { textField in
            textField.textContentType = .oneTimeCode
            textField.placeholder = "Authenticaton or recovery code"
        }

        let submitAction = UIAlertAction(title: "Continue", style: .default) { [unowned alertController] _ in
            guard let code = alertController.textFields![0].text else { return }
            self.verifyTOTP(code: code)
        }

        alertController.addAction(submitAction)

        self.present(alertController, animated: true, completion: nil)
    }

    func verifyTOTP(code: String) {
        api.verifyTOTP(code: code) { result in
            switch result {
            case .success(let data):
                self.verifyOTPSuccess(token: data.token)

            case .failure(let error):
                self.verifyOTPFailure(error: error)
            }
        }
    }

    func verifyOTPSuccess (token: String) {
        self.authenticate(token: token)
    }

    func verifyOTPFailure (error: PutioAPIError) {
        self.setLoginButtonState(isBusy: false)
        let localizedError = AuthErrors.localizeTwoFactorAuthError(error: error)
        let alert = UIAlertController(title: localizedError.message, message: localizedError.recoverySuggestion.description, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
        return self.present(alert, animated: true, completion: nil)
    }

    func setLoginButtonState(isBusy: Bool = false) {
        let isEnabled = !isBusy && !usernameField.text!.isEmpty && passwordField.text!.count >= 4

        loginButton.isEnabled = isEnabled
        loginButton.alpha = isEnabled ? 1 : 0.3

        if isBusy {
            activityIndicator.startAnimating()
            loginButton.setTitle("", for: .normal)
        } else {
            activityIndicator.stopAnimating()
            loginButton.setTitle("Log in", for: .normal)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == usernameField && !(textField.text?.isEmpty)! {
            textField.resignFirstResponder()
            passwordField.becomeFirstResponder()
            return true
        }

        if textField == passwordField && textField.text!.count >= 4 {
            passwordField.resignFirstResponder()
            login()
            return true
        }

        return false
    }

    @IBAction func usernameChanged(_ sender: Any) {
        setLoginButtonState()
    }

    @IBAction func passwordChanged(_ sender: Any) {
        setLoginButtonState()
    }

    @IBAction func loginButtonPressed(_ sender: Any) {
        login()
    }

    func startWebAuthFlow() {
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

    @IBAction func alternativeLoginMethodButtonPressed(_ sender: Any) {
        self.startWebAuthFlow()
    }
}

extension LoginViewController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return view.window ?? ASPresentationAnchor()
    }
}
