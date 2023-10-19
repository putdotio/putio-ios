import UIKit
import StatefulViewController

class TwoFactorRecoveryCodesViewController: UIViewController, StatefulViewController {
    enum Action {
        case confirmSave
        case regenerateCodes
    }

    var action: Action = .confirmSave
    let viewModel = TwoFactorRecoveryCodesViewModel()

    @IBOutlet weak var bannerView: UIView!
    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var buttonStackView: UIStackView!
    @IBOutlet weak var primaryButton: UIButton!
    @IBOutlet weak var secondaryButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()

        configureAppearance()
        configureStateMachine()

        tableView.delegate = self
        tableView.dataSource = self

        viewModel.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        switch viewModel.state {
        case .idle:
            viewModel.fetchRecoveryCodes()
        default:
            break
        }
    }

    func configureAppearance() {
        navigationItem.largeTitleDisplayMode = .never

        switch action {
        case .confirmSave:
            primaryButton.setTitle("I have saved my recovery codes", for: .normal)
            navigationItem.hidesBackButton = true
        case .regenerateCodes:
            primaryButton.setTitle("Regenerate", for: .normal)
        }

        secondaryButton.setTitle("Copy all", for: .normal)

        bannerView.isHidden = true
        tableView.isHidden = true
        buttonStackView.isHidden = true
    }

    func configureStateMachine() {
        let loadingView = LoaderView.instantiateFromInterfaceBuilder()
        stateMachine.addView(loadingView, forState: "loading")

        let errorView = EmptyStateView.instantiateFromInterfaceBuilder()
        errorView.configure(heading: "Oops", description: "An error occurred, please try again :(")
        stateMachine.addView(errorView, forState: "error")

        let offlineStatusView = OfflineStatusView.instantiateFromInterfaceBuilder()
        stateMachine.addView(offlineStatusView, forState: "offline")

        stateMachine.transitionToState(.view("loading"))
    }

    @IBAction func primaryButtonTapped(_ sender: Any) {
        switch action {
        case .confirmSave:
            navigationController?.dismiss(animated: true)
        case .regenerateCodes:
            viewModel.regenerateRecoveryCodes { _ in }
        }
    }

    @IBAction func secondaryButtonTapped(_ sender: Any) {
        switch viewModel.state {
        case .success(data: let data):
            let codes = data.codes
                .filter { $0.used_at == "" }
                .map { $0.code }
                .joined(separator: "\n")

            let pasteboard = UIPasteboard.general
            pasteboard.string = codes

            secondaryButton.setTitle("Copied!", for: .normal)
            Utils.delayWithSeconds(3) {
                self.secondaryButton.setTitle("Copy all", for: .normal)
            }

        default:
            return
        }
    }
}

extension TwoFactorRecoveryCodesViewController: TwoFactorRecoveryCodesViewModelDelegate {
    func stateChanged() {
        switch viewModel.state {
        case .loading, .idle:
            stateMachine.transitionToState(.view("loading"))

        case .success:
            stateMachine.transitionToState(.none)

            bannerView.isHidden = false
            tableView.isHidden = false
            buttonStackView.isHidden = false

            tableView.reloadData()

        case .failure:
            stateMachine.transitionToState(.view("error"), animated: false, completion: nil)
        }
    }
}

extension TwoFactorRecoveryCodesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
    }
}

extension TwoFactorRecoveryCodesViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch viewModel.state {
        case .success(data: let data):
            return data.codes.count

        default:
            return 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "recoveryCodeReuse", for: indexPath) as! TwoFactorRecoveryCodesTableViewCell

        switch viewModel.state {
        case .success(data: let data):
            let code = data.codes[indexPath.row]

            cell.isUserInteractionEnabled = code.used_at == ""
            cell.configure(with: code)

            return cell

        default:
            return cell
        }
    }
}
