import UIKit
import PutioSDK

enum VideoConversionIntention {
    case play, download
}

protocol VideoConversionViewControllerDelegate: AnyObject {
    func videoConversionFinished(for file: PutioFile, intention: VideoConversionIntention)
    func videoConversionControllerDismissedBeforeFinish()
}

class VideoConversionViewController: UIViewController {
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var progressView: UIProgressView!

    weak var delegate: VideoConversionViewControllerDelegate?

    var file: PutioFile!
    var intention: VideoConversionIntention!
    lazy var session = VideoConversionSession(fileID: file.id)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureAppearance()
        session.delegate = self
        session.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            session.cancel()
        }
    }

    func configureAppearance() {
        navigationItem.title = file.name.truncate(length: 24)
        statusLabel.numberOfLines = 0
        showProgress(status: NSLocalizedString("Waiting...", comment: ""), percentDone: 0)
    }

    @IBAction func closeButtonTapped(_ sender: Any) {
        session.cancel()
        dismiss(animated: true) {
            self.delegate?.videoConversionControllerDismissedBeforeFinish()
        }
    }

    private func render(_ state: VideoConversionSession.State) {
        switch state {
        case .idle, .starting:
            showProgress(status: NSLocalizedString("Waiting...", comment: ""), percentDone: 0)

        case .converting(let progress):
            showProgress(status: Self.statusText(for: progress.status), percentDone: progress.percentDone)

        case .fetchingConvertedFile:
            showProgress(status: NSLocalizedString("Completed, video will automatically play!", comment: ""), percentDone: 1)

        case .finished(let convertedFile):
            finish(with: convertedFile)

        case .failed(let failure):
            showFailure(failure)

        case .cancelled:
            break
        }
    }

    private func showProgress(status: String, percentDone: Float) {
        statusLabel.text = status
        progressView.isHidden = false
        progressView.progress = percentDone
        navigationItem.rightBarButtonItem = nil
    }

    private func showFailure(_ failure: VideoConversionSession.Failure) {
        let presentation = Self.failurePresentation(for: failure)
        statusLabel.text = presentation.message
        progressView.isHidden = true
        navigationItem.rightBarButtonItem = presentation.canRetry ? UIBarButtonItem(
            title: NSLocalizedString("Retry", comment: ""),
            primaryAction: UIAction { [weak self] _ in
                self?.session.start()
            }
        ) : nil
    }

    private func finish(with convertedFile: PutioFile) {
        let delegate = self.delegate
        let intention = self.intention!
        dismiss(animated: true) {
            delegate?.videoConversionFinished(for: convertedFile, intention: intention)
        }
    }

    static func statusText(for status: PutioMp4Conversion.Status) -> String {
        switch status {
        case .queued:
            return NSLocalizedString("In Queue", comment: "")
        default:
            return NSLocalizedString("Converting...", comment: "")
        }
    }

    static func failurePresentation(for failure: VideoConversionSession.Failure) -> (message: String, canRetry: Bool) {
        switch failure {
        case .start(let error), .status(let error), .convertedFile(let error):
            let localizedError = api.localizeError(error: error)
            return ("\(localizedError.message)\n\(localizedError.recoverySuggestion.description)", true)

        case .conversion(.notAvailable):
            return (NSLocalizedString("This video can't be converted", comment: ""), false)

        case .conversion:
            return (
                "\(NSLocalizedString("This video couldn't be converted", comment: ""))\n\(NSLocalizedString("Please try again later", comment: ""))",
                true
            )
        }
    }
}

extension VideoConversionViewController: VideoConversionSessionDelegate {
    func videoConversionSessionStateChanged(_ session: VideoConversionSession) {
        render(session.state)
    }
}
