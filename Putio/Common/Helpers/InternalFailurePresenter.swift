import os
import UIKit

enum InternalFailurePresenter {
    typealias ReportedContexts = OSAllocatedUnfairLock<Set<String>>

    private static let reportedContexts = ReportedContexts(initialState: [])

    static func log(_ message: String, context: StaticString, error: Error? = nil) {
        log(message, context: context, error: error, reportingOnceIn: reportedContexts)
    }

    static func log(_ message: String, context: StaticString, error: Error?, reportingOnceIn reported: ReportedContexts) {
        logLocally(message)
        let context = context.description
        guard SentryTelemetry.isCapturing,
              reported.withLock({ $0.insert(context).inserted })
        else { return }
        SentryTelemetry.capture(.internalFailure, error: error, context: context)
    }

    static func logLocally(_ message: String) {
        Putio.log.error("[InternalFailure] \(message)")
    }

    static func present(
        on presenter: UIViewController?,
        screen: AnalyticsEvent.Screen,
        title: String = NSLocalizedString("Oops", comment: ""),
        message: String = NSLocalizedString("Something unexpected happened. Please try again.", comment: "")
    ) {
        guard let presenter = presenter else {
            log("Unable to present alert: \(title) — \(message)", context: "InternalFailurePresenter.present")
            return
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel))
        presenter.present(alert, animated: true) {
            ProductAnalytics.capture(.errorShown(screen))
        }
    }

    static func logAndPresent(
        on presenter: UIViewController?,
        screen: AnalyticsEvent.Screen,
        logMessage: String,
        context: StaticString,
        title: String = NSLocalizedString("Oops", comment: ""),
        message: String = NSLocalizedString("Something unexpected happened. Please try again.", comment: "")
    ) {
        log(logMessage, context: context)
        present(on: presenter, screen: screen, title: title, message: message)
    }
}
