import UIKit
import PutioSDK

protocol VideoConversionPresenter {}

extension VideoConversionPresenter where Self: UIViewController {
    func presentVideoConversionView(for file: PutioFile, intention: VideoConversionIntention) {
        let storyboard = UIStoryboard(name: "VideoConversion", bundle: nil)
        let videoConversionNC = storyboard.instantiateViewController(withIdentifier: "VideoConversionNC") as! UINavigationController
        let videoConversionVC = videoConversionNC.viewControllers[0] as! VideoConversionViewController

        videoConversionVC.file = file
        videoConversionVC.intention = intention
        videoConversionVC.delegate = self as? VideoConversionViewControllerDelegate

        self.present(videoConversionNC, animated: true, completion: nil)
    }
}
