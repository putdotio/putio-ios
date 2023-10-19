import Foundation
import PutioAPI

class ClearDataViewModel {
    enum ActionResult {
        case success
        case failure(error: PutioAPIError)
    }

    typealias ActionCompletion = ((_ result: ActionResult) -> Void)

    lazy var keys: [String] = PutioClearDataOptionKeys
    lazy var options: [String: Bool] = Dictionary(uniqueKeysWithValues: PutioClearDataOptionKeys.map { ($0, false) })

    func toggleOption(key: String) {
        guard let option = options[key] else { return }
        options.updateValue(!option, forKey: key)
    }

    func startCleanUp(completion: @escaping ActionCompletion) {
        api.clearAccountData(options: options) { result in
            switch result {
            case .success:
                completion(.success)

            case .failure(let error):
                completion(.failure(error: error))
            }
        }
    }
}
