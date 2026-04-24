import Foundation
import PutioSDK

class ClearDataViewModel {
    enum ActionResult {
        case success
        case failure(error: PutioSDKError)
    }

    typealias ActionCompletion = ((_ result: ActionResult) -> Void)

    lazy var keys: [String] = PutioClearDataOptionKeys
    lazy var options: [String: Bool] = Dictionary(uniqueKeysWithValues: PutioClearDataOptionKeys.map { ($0, false) })

    func toggleOption(key: String) {
        guard let option = options[key] else { return }
        options.updateValue(!option, forKey: key)
    }

    func startCleanUp(completion: @escaping ActionCompletion) {
        api.clearAccountData(options: PutioAccountClearOptions(
            files: options["files"] ?? false,
            finishedTransfers: options["finished_transfers"] ?? false,
            activeTransfers: options["active_transfers"] ?? false,
            rssFeeds: options["rss_feeds"] ?? false,
            rssLogs: options["rss_logs"] ?? false,
            history: options["history"] ?? false,
            trash: options["trash"] ?? false,
            friends: options["friends"] ?? false
        )) { result in
            switch result {
            case .success:
                completion(.success)

            case .failure(let error):
                completion(.failure(error: error))
            }
        }
    }
}
