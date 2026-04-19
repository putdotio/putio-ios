import UIKit
import Foundation

// https://developer.apple.com/documentation/storekit/skstorereviewcontroller/requesting_app_store_reviews
class AppStoreReviewManager {
    static let sharedInstance = AppStoreReviewManager()

    func requestReviewManually() {
        guard let writeReviewURL = URL(string: "https://apps.apple.com/app/\(APP_STORE_APP_ID)?action=write-review") else {
            return InternalFailurePresenter.log("Unable to construct App Store review URL")
        }
        UIApplication.shared.open(writeReviewURL, options: [:], completionHandler: nil)
    }
}
