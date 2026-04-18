import Foundation
import PutioSDK

protocol TwoFactorRecoveryCodesViewModelDelegate: class {
    func stateChanged()
}

class TwoFactorRecoveryCodesViewModel {
    enum State {
        case idle
        case loading
        case success(data: PutioTwoFactorRecoveryCodes)
        case failure(error: Error)
    }

    enum ActionResult {
        case success
        case failure(error: Error)
    }

    typealias ActionCompletion = ((_ result: ActionResult) -> Void)

    weak var delegate: TwoFactorRecoveryCodesViewModelDelegate?

    var state: State = .idle {
        didSet {
            self.delegate?.stateChanged()
        }
    }

    func fetchRecoveryCodes() {
        api.getRecoveryCodes { result in
            switch result {
            case .success(let data):
                self.state = .success(data: data)
            case .failure(let error):
                self.state = .failure(error: error)
            }
        }
    }

    func regenerateRecoveryCodes(completion: @escaping ActionCompletion) {
        state = .loading

        api.regenerateRecoveryCodes { result in
            switch result {
            case .success(let data):
                self.state = .success(data: data)
            case .failure(let error):
                self.state = .failure(error: error)
            }
        }
    }
}
