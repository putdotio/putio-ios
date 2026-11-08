import UIKit
import PDFKit
import PutioSDK

class PDFViewController: UIViewController {
    var file: PutioFile?
    private var request: URLSessionDataTask?
    private var openSignpost: PerfSignpost.Interval?

    @IBOutlet weak var pdfView: PDFView!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet weak var loadingText: UILabel!

    deinit {
        cancelRequest()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        configureAppearance()
        loadPlaceholderPDF()

        if let file = file {
            title = file.name
            openSignpost = PerfSignpost.begin("PDFOpen")
            downloadAndShowPDF()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            cancelRequest()
        }
    }

    func configureAppearance() {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.isUserInteractionEnabled = false
    }

    func loadPlaceholderPDF() {
        guard let url = Bundle.main.url(forResource: "blank", withExtension: "pdf"),
              let pdfDocument = PDFDocument(url: url) else {
            InternalFailurePresenter.log("Unable to load placeholder PDF", context: "PDFViewController.loadPlaceholderPDF")
            return
        }

        pdfView.document = pdfDocument
    }

    func downloadAndShowPDF() {
        guard let file = file else {
            finishLoading()
            return presentErrorMessage(message: NSLocalizedString("An error occurred while fetching the PDF", comment: ""))
        }

        let url = file.getDownloadURL(downloadToken: api.mediaToken)

        request = MediaPreviewSession.shared.dataTask(with: url) { [weak self] data, response, error in
            if (error as? URLError)?.code == .cancelled { return }

            guard let data = MediaPreviewSession.body(data, of: response) else {
                let message = MediaPreviewSession.fetchFailureMessage(
                    for: response,
                    otherwise: NSLocalizedString("An error occurred while fetching the PDF", comment: "")
                )
                return DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.request != nil else { return }
                    self.finishLoading()
                    self.presentErrorMessage(message: message)
                    self.endOpenSignpost()
                }
            }

            guard self != nil else { return }

            guard let pdfDocument = PDFDocument(data: data) else {
                return DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.request != nil else { return }
                    self.finishLoading()
                    self.presentErrorMessage(message: NSLocalizedString("An error occurred while displaying the PDF", comment: ""))
                    self.endOpenSignpost()
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.request != nil else { return }
                self.finishLoading()
                self.pdfView.isUserInteractionEnabled = true
                self.pdfView.document = pdfDocument
                self.pdfView.accessibilityIdentifier = "putio-preview-content"
                // After the commit, which lays out the document's pages.
                self.endOpenSignpost()
            }
        }
        request?.resume()
    }

    private func cancelRequest() {
        request?.cancel()
        request = nil
        endOpenSignpost(afterCommit: false)
    }

    private func endOpenSignpost(afterCommit: Bool = true) {
        guard let signpost = openSignpost else { return }
        openSignpost = nil
        if afterCommit {
            PerfSignpost.endAfterCommit(signpost)
        } else {
            PerfSignpost.end(signpost)
        }
    }

    private func finishLoading() {
        activityIndicator.stopAnimating()
        loadingText.isHidden = true
    }

    func presentErrorMessage(message: String) {
        let alertController = UIAlertController(
            title: NSLocalizedString("Oops!", comment: ""),
            message: message,
            preferredStyle: .alert
        )

        let goBackAction = UIAlertAction(title: NSLocalizedString("Go Back", comment: ""), style: .default) { (_) in
            self.navigationController?.popViewController(animated: true)
        }

        alertController.addAction(goBackAction)
        present(alertController, animated: true, completion: nil)
    }
}
