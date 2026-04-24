import UIKit
import PDFKit
import PutioSDK

class PDFViewController: UIViewController {
    var file: PutioFile?
    private var request: URLSessionDataTask?

    @IBOutlet weak var pdfView: PDFView!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet weak var loadingText: UILabel!

    override func viewDidLoad() {
        super.viewDidLoad()

        configureAppearance()
        loadPlaceholderPDF()

        if let file = file {
            title = file.name
            downloadAndShowPDF()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            request?.cancel()
            request = nil
        }
    }

    func configureAppearance() {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.isUserInteractionEnabled = false
    }

    func loadPlaceholderPDF() {
        let path = Bundle.main.path(forResource: "blank", ofType: "pdf")
        let url = URL(fileURLWithPath: path!)
        let pdfDocument = PDFDocument(url: url)
        pdfView.document = pdfDocument
    }

    func downloadAndShowPDF() {
        let url = file!.getDownloadURL(token: api.config.token)

        request = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }
            if (error as? URLError)?.code == .cancelled { return }

            guard let data = data else {
                return DispatchQueue.main.async {
                    self.finishLoading()
                    self.presentErrorMessage(message: NSLocalizedString("An error occurred while fetching the PDF", comment: ""))
                }
            }

            guard let pdfDocument = PDFDocument(data: data) else {
                return DispatchQueue.main.async {
                    self.finishLoading()
                    self.presentErrorMessage(message: NSLocalizedString("An error occurred while displaying the PDF", comment: ""))
                }
            }

            DispatchQueue.main.async {
                self.finishLoading()
                self.pdfView.isUserInteractionEnabled = true
                self.pdfView.document = pdfDocument
            }
        }
        request?.resume()
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
