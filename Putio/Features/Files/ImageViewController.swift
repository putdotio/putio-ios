import UIKit
import PutioSDK
import os

class ImageViewController: UIViewController {
    var file: PutioFile?
    private var request: URLSessionDataTask?
    private var openSignpost: OSSignpostIntervalState?

    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet weak var loadingText: UILabel!

    deinit {
        cancelRequest()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        if let file = file {
            title = file.name
            let signposter = PerfSignpost.signposter
            openSignpost = signposter.beginInterval("ImageOpen", id: signposter.makeSignpostID(), "file \(file.id)")
            loadImage()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            cancelRequest()
        }
    }

    func loadImage() {
        guard let file = file else {
            finishLoading()
            return presentErrorMessage(message: NSLocalizedString("An error occurred while fetching the image", comment: ""))
        }

        let url = file.getDownloadURL(downloadToken: api.mediaToken)

        request = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }
            if (error as? URLError)?.code == .cancelled { return }

            guard let data = data else {
                return DispatchQueue.main.async {
                    self.finishLoading()
                    self.presentErrorMessage(message: NSLocalizedString("An error occurred while fetching the image", comment: ""))
                    self.endOpenSignpost()
                }
            }

            guard let image = UIImage(data: data) else {
                return DispatchQueue.main.async {
                    self.finishLoading()
                    self.presentErrorMessage(message: NSLocalizedString("An error occurred while displaying the image", comment: ""))
                    self.endOpenSignpost()
                }
            }

            DispatchQueue.main.async {
                self.finishLoading()
                self.imageView.image = image
                // After the commit, which is where UIKit decodes the image.
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
            PerfSignpost.endAfterCommit("ImageOpen", signpost)
        } else {
            PerfSignpost.signposter.endInterval("ImageOpen", signpost)
        }
    }

    private func finishLoading() {
        activityIndicator.stopAnimating()
        loadingText.isHidden = true
    }

    func presentErrorMessage(message: String) {
        let errorAlert = UIAlertController(
            title: NSLocalizedString("Oops!", comment: ""),
            message: message,
            preferredStyle: .alert
        )

        let goBackAction = UIAlertAction(title: NSLocalizedString("Go Back", comment: ""), style: .default) { (_) in
            self.navigationController?.popViewController(animated: true)
        }

        errorAlert.addAction(goBackAction)
        present(errorAlert, animated: true, completion: nil)
    }
}
