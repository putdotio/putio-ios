import UIKit
import Alamofire
import PutioAPI

class ImageViewController: UIViewController {
    var file: PutioFile?

    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet weak var loadingText: UILabel!

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.largeTitleDisplayMode = .never

        if let file = file {
            title = file.name
            loadImage()
        }
    }

    func loadImage() {
        let url = file!.getDownloadURL(token: api.config.token)

        AF.request(url.absoluteString).responseData { (response) in
            DispatchQueue.main.async {
                self.activityIndicator.stopAnimating()
                self.loadingText.isHidden = true
            }

            guard let data = response.data else {
                return self.presentErrorMessage(message: "An error occurred while fetching the Image")
            }

            guard let image = UIImage(data: data) else {
                return self.presentErrorMessage(message: "An error occurred while displaying the image")
            }

            DispatchQueue.main.async {
                self.imageView.image = image
            }
        }
    }

    func presentErrorMessage(message: String) {
        let errorAlert = UIAlertController(
            title: "Oops!",
            message: message,
            preferredStyle: .alert
        )

        let goBackAction = UIAlertAction(title: "Go Back", style: .default) { (_) in
            self.navigationController?.popViewController(animated: true)
        }

        errorAlert.addAction(goBackAction)
        present(errorAlert, animated: true, completion: nil)
    }
}
