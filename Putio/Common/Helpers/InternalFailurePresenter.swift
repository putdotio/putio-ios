import UIKit

enum InternalFailurePresenter {
    static func log(_ message: String) {
        Putio.log.error("[InternalFailure] \(message)")
    }

    static func present(
        on presenter: UIViewController?,
        title: String = NSLocalizedString("Oops", comment: ""),
        message: String = NSLocalizedString("Something unexpected happened. Please try again.", comment: "")
    ) {
        guard let presenter = presenter else {
            log("Unable to present alert: \(title) — \(message)")
            return
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel))
        presenter.present(alert, animated: true)
    }

    static func logAndPresent(
        on presenter: UIViewController?,
        logMessage: String,
        title: String = NSLocalizedString("Oops", comment: ""),
        message: String = NSLocalizedString("Something unexpected happened. Please try again.", comment: "")
    ) {
        log(logMessage)
        present(on: presenter, title: title, message: message)
    }
}
