import UIKit
import PDFKit
import Alamofire
import PutioSDK

class PDFViewController: UIViewController {
    var file: PutioFile?
    private var request: DataRequest?

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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        request?.cancel()
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

        request = AF.request(url.absoluteString).responseData { [weak self] (response) in
            guard let self = self else { return }

            DispatchQueue.main.async {
                self.activityIndicator.stopAnimating()
                self.loadingText.isHidden = true
            }

            guard let data = response.data else {
                return self.presentErrorMessage(message: "An error occurred while fetching the PDF")
            }

            guard let pdfDocument = PDFDocument(data: data) else {
                return self.presentErrorMessage(message: "An error occurred while displaying the PDF")
            }

            DispatchQueue.main.async {
                self.pdfView.isUserInteractionEnabled = true
                self.pdfView.document = pdfDocument
            }
        }
    }

    func presentErrorMessage(message: String) {
        let alertController = UIAlertController(
            title: "Oops!",
            message: message,
            preferredStyle: .alert
        )

        let goBackAction = UIAlertAction(title: "Go Back", style: .default) { (_) in
            self.navigationController?.popViewController(animated: true)
        }

        alertController.addAction(goBackAction)
        present(alertController, animated: true, completion: nil)
    }
}
