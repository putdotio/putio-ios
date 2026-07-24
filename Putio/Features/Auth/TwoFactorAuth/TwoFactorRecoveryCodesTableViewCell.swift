import UIKit
import PutioSDK

class TwoFactorRecoveryCodesTableViewCell: UITableViewCell {
    var code: PutioTwoFactorRecoveryCode?

    private func renderWithCode() {
        guard let code = self.code else { return }

        self.textLabel?.text = code.code
        // Recovery codes are machine-readable strings the user copies/records,
        // so render them in the design system's code face (Berkeley Mono).
        self.textLabel?.applyBrandStyle(.code)

        if let date = code.usedAt, !date.isEmpty {
            self.detailTextLabel?.text = String(
                format: NSLocalizedString("Used on %@", comment: ""),
                date
            )
        } else {
            self.detailTextLabel?.text = ""
        }
    }

    private func renderWithCopiedText() {
        self.textLabel?.text = NSLocalizedString("Copied!", comment: "")
        self.textLabel?.applyBrandStyle(.code)

        Utils.delayWithSeconds(1) {
            self.renderWithCode()
        }
    }

    func configure(with code: PutioTwoFactorRecoveryCode) {
        self.code = code
        self.renderWithCode()
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        if selected {
            guard let code = self.code else { return }

            let pasteboard = UIPasteboard.general
            pasteboard.string = code.code

            renderWithCopiedText()
        }
    }
}
