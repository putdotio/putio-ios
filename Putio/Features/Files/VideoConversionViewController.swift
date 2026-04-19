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

    var shouldCheckConvertionStatus = false
    var file: PutioFile!
    var intention: VideoConversionIntention!
    var status = PutioMp4Conversion.Status.queued {
        didSet {
            var label = NSLocalizedString("Waiting...", comment: "")

            switch self.status {
            case PutioMp4Conversion.Status.queued:
                label = NSLocalizedString("In Queue", comment: "")

            case PutioMp4Conversion.Status.converting:
                label = NSLocalizedString("Converting...", comment: "")

            case PutioMp4Conversion.Status.completed:
                label = NSLocalizedString("Completed, video will automatically play!", comment: "")

            case PutioMp4Conversion.Status.error, PutioMp4Conversion.Status.notAvailable:
                label = NSLocalizedString("Error", comment: "")
            }

            statusLabel.text = label
        }
    }
    var percentDone: Float = 0.0 {
        didSet {
            progressView.progress = percentDone
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureApperance()
        startConversion()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        shouldCheckConvertionStatus = false
    }

    func configureApperance() {
        navigationItem.title = file.name.truncate(length: 24)
        statusLabel.text = NSLocalizedString("Waiting...", comment: "")
        progressView.progress = percentDone
    }

    func startConversion() {
        api.startMp4Conversion(fileID: file.id) { result in
            switch result {
            case .success:
                self.shouldCheckConvertionStatus = true
                self.checkConversionStatus()

            case .failure:
                break
            }
        }
    }

    func checkConversionStatus() {
        api.getMp4ConversionStatus(fileID: file.id) { result in
            switch result {
            case .success(let conversion):
                let strongSelf = self

                if conversion.status == .completed {
                    return api.getFile(fileID: strongSelf.file.id) { result in
                        switch result {
                        case .success(let convertedFile):
                            strongSelf.dismiss(animated: true, completion: {
                                strongSelf.delegate?.videoConversionFinished(for: convertedFile, intention: strongSelf.intention)
                            })

                        case .failure:
                            break
                        }
                    }
                }

                strongSelf.status = conversion.status
                strongSelf.percentDone = conversion.percentDone

                if strongSelf.shouldCheckConvertionStatus {
                    Utils.delayWithSeconds(3, completion: {
                        strongSelf.checkConversionStatus()
                    })
                }

            case .failure:
                break
            }
        }
    }

    @IBAction func closeButtonTapped(_ sender: Any) {
        dismiss(animated: true) {
            self.delegate?.videoConversionControllerDismissedBeforeFinish()
        }
    }
}
