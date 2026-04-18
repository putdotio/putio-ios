import Foundation
import PutioSDK

protocol EnableTwoFactorSecretViewModelDelegate: AnyObject {
    func stateChanged()
}

class EnableTwoFactorSecretViewModel {
    enum State {
        case idle
        case loading
        case success(data: String)
        case failure(error: Error)
    }

    enum ActionResult {
        case success
        case failure(error: Error)
    }

    typealias ActionCompletion = ((_ result: ActionResult) -> Void)

    weak var delegate: EnableTwoFactorSecretViewModelDelegate?

    var state: State = .idle {
        didSet {
            self.delegate?.stateChanged()
        }
    }

    func fetchSecret() {
        self.state = .loading

        api.generateTOTP { result in
            switch result {
            case .success(let data):
                let secret = data.secret
                    .enumerated()
                    .map { $0.isMultiple(of: 4) && ($0 != 0) ? "-\($1)" : String($1) }
                    .joined()

                self.state = .success(data: secret)

            case .failure(let error):
                self.state = .failure(error: error)
            }
        }
    }
}
