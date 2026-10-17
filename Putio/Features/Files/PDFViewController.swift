import UIKit
import PDFKit
import PutioSDK
import os

class PDFViewController: UIViewController {
    var file: PutioFile?
    private var request: URLSessionDataTask?
    private var openSignpost: OSSignpostIntervalState?

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
            let signposter = PerfSignpost.signposter
            openSignpost = signposter.beginInterval("PDFOpen", id: signposter.makeSignpostID(), "file \(file.id)")
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
            InternalFailurePresenter.log("Unable to load placeholder PDF")
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

        request = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }
            if (error as? URLError)?.code == .cancelled { return }

            guard let data = data else {
                return DispatchQueue.main.async {
                    self.finishLoading()
                    self.presentErrorMessage(message: NSLocalizedString("An error occurred while fetching the PDF", comment: ""))
                    self.endOpenSignpost()
                }
            }

            guard let pdfDocument = PDFDocument(data: data) else {
                return DispatchQueue.main.async {
                    self.finishLoading()
                    self.presentErrorMessage(message: NSLocalizedString("An error occurred while displaying the PDF", comment: ""))
                    self.endOpenSignpost()
                }
            }

            DispatchQueue.main.async {
                self.finishLoading()
                self.pdfView.isUserInteractionEnabled = true
                self.pdfView.document = pdfDocument
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
            PerfSignpost.endAfterCommit("PDFOpen", signpost)
        } else {
            PerfSignpost.signposter.endInterval("PDFOpen", signpost)
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
