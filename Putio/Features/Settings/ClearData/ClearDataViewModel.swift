import Foundation
import PutioSDK

class ClearDataViewModel {
    enum ActionResult {
        case success
        case failure(error: PutioSDKError)
    }

    typealias ActionCompletion = ((_ result: ActionResult) -> Void)
    typealias ClearRequest = (PutioAccountClearOptions, @escaping (Result<PutioOKResponse, PutioSDKError>) -> Void) -> Void
    typealias Confirm = (_ message: String, _ answer: @escaping (_ confirmed: Bool) -> Void) -> Void

    private static let titles: [String: String] = [
        "files": NSLocalizedString("Files", comment: ""),
        "finished_transfers": NSLocalizedString("Finished transfers", comment: ""),
        "active_transfers": NSLocalizedString("Active transfers", comment: ""),
        "rss_feeds": NSLocalizedString("RSS feeds", comment: ""),
        "rss_logs": NSLocalizedString("RSS logs", comment: ""),
        "history": NSLocalizedString("History", comment: ""),
        "trash": NSLocalizedString("Trash", comment: ""),
        "friends": NSLocalizedString("Friends", comment: "")
    ]

    private let clearRequest: ClearRequest
    private var isClearing = false

    lazy var keys: [String] = PutioClearDataOptionKeys
    lazy var options: [String: Bool] = Dictionary(uniqueKeysWithValues: PutioClearDataOptionKeys.map { ($0, false) })

    init(clearRequest: @escaping ClearRequest = { options, completion in
        api.clearAccountData(options: options, completion)
    }) {
        self.clearRequest = clearRequest
    }

    var selectedKeys: [String] {
        keys.filter { options[$0] == true }
    }

    var canClear: Bool {
        !isClearing && !selectedKeys.isEmpty
    }

    var confirmationMessage: String {
        String(
            format: NSLocalizedString(
                "This permanently deletes %@ from your put.io account. It can't be undone.",
                comment: "%@ is the selected categories, for example \"Files, History, and Trash\"."
            ),
            ListFormatter.localizedString(byJoining: selectedKeys.map(title(for:)))
        )
    }

    func title(for key: String) -> String {
        Self.titles[key] ?? key
    }

    func toggleOption(key: String) {
        guard let option = options[key] else { return }
        options.updateValue(!option, forKey: key)
    }

    // Sends the request only after `confirm` answers true, with the selection
    // the confirmation named.
    func cleanUp(confirm: Confirm, completion: @escaping ActionCompletion) {
        guard canClear else { return }

        isClearing = true
        let clearOptions = PutioAccountClearOptions(
            files: options["files"] ?? false,
            finishedTransfers: options["finished_transfers"] ?? false,
            activeTransfers: options["active_transfers"] ?? false,
            rssFeeds: options["rss_feeds"] ?? false,
            rssLogs: options["rss_logs"] ?? false,
            history: options["history"] ?? false,
            trash: options["trash"] ?? false,
            friends: options["friends"] ?? false
        )

        confirm(confirmationMessage) { confirmed in
            guard confirmed else {
                self.isClearing = false
                return
            }

            self.clearRequest(clearOptions) { result in
                self.isClearing = false

                switch result {
                case .success:
                    completion(.success)

                case .failure(let error):
                    completion(.failure(error: error))
                }
            }
        }
    }
}
