import UIKit
import ImageIO
import PutioSDK

class ImageViewController: UIViewController {
    var file: PutioFile?
    private var request: URLSessionDataTask?
    private var openSignpost: PerfSignpost.Interval?

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
            openSignpost = PerfSignpost.begin("ImageOpen")
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
        // viewDidLoad runs before this view joins a window.
        let maxPixelSize = ImagePreviewDecoder.maxPixelSize(on: navigationController?.view.window ?? view.window)

        request = MediaPreviewSession.shared.dataTask(with: url) { [weak self] data, _, error in
            if (error as? URLError)?.code == .cancelled { return }

            guard let data = data else {
                return DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.request != nil else { return }
                    self.finishLoading()
                    self.presentErrorMessage(message: NSLocalizedString("An error occurred while fetching the image", comment: ""))
                    self.endOpenSignpost()
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let image = ImagePreviewDecoder.decode(data, maxPixelSize: maxPixelSize)

                DispatchQueue.main.async { [weak self] in
                    // Back navigation clears the request, possibly while this decoded.
                    guard let self = self, self.request != nil else { return }
                    self.finishLoading()

                    guard let image = image else {
                        self.presentErrorMessage(message: NSLocalizedString("An error occurred while displaying the image", comment: ""))
                        return self.endOpenSignpost()
                    }

                    self.imageView.image = image
                    self.endOpenSignpost()
                }
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

/// Decodes a preview into a bitmap no larger than the screen can show. Left to
/// `UIImage(data:)`, a 48 MP photo decodes at full size, about 190 MB, on main
/// at the first commit that displays it.
enum ImagePreviewDecoder {
    /// The screen's longest side in pixels, which bounds an aspect-fit preview
    /// in either orientation. Nil, with no window, decodes at full size.
    static func maxPixelSize(on window: UIWindow?) -> Int? {
        guard let bounds = window?.windowScene?.screen.nativeBounds else { return nil }
        return Int(max(bounds.width, bounds.height))
    }

    static func decode(_ data: Data, maxPixelSize: Int?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }

        var options: [CFString: Any] = [
            // Never the embedded EXIF thumbnail, which is far smaller.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation, as UIImage(data:) does.
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decodes here rather than at the first commit.
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let maxPixelSize = maxPixelSize {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        }

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}
