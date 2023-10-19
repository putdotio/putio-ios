import Foundation
import UIKit

let TWO_FACTOR_AUTH_STORYBOARD = UIStoryboard(name: "TwoFactorAuth", bundle: nil)

protocol TwoFactorAuthPresenter {}

extension TwoFactorAuthPresenter where Self: UIViewController {
    func toTwoFactorRecoveryCodes(action: TwoFactorRecoveryCodesViewController.Action) {
        let vc = TWO_FACTOR_AUTH_STORYBOARD
            .instantiateViewController(withIdentifier: "TwoFactorRecoveryCodesVC") as! TwoFactorRecoveryCodesViewController

        vc.action = action
        self.navigationController?.pushViewController(vc, animated: true)
    }

    func toEnableTwoFactor() {
        let nc = TWO_FACTOR_AUTH_STORYBOARD
            .instantiateViewController(withIdentifier: "EnableTwoFactorNC") as! UINavigationController

        self.navigationController?.present(nc, animated: true)
    }

    func toDisableTwoFactor() {
        let nc = TWO_FACTOR_AUTH_STORYBOARD
            .instantiateViewController(withIdentifier: "DisableTwoFactorNC") as! UINavigationController

        self.navigationController?.present(nc, animated: true)
    }
}
