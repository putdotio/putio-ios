import UIKit
import StatefulViewController

class EnableTwoFactorSecretViewController: UIViewController, StatefulViewController {
    let viewModel = EnableTwoFactorSecretViewModel()

    @IBOutlet weak var secretLabel: UILabel!
    @IBOutlet weak var copyButton: UIButton!
    @IBOutlet weak var nextButton: Button!

    override func viewDidLoad() {
        super.viewDidLoad()

        configureStateMachine()

        viewModel.delegate = self
        viewModel.fetchSecret()
    }

    func configureStateMachine() {
        let loadingView = LoaderView.instantiateFromInterfaceBuilder()
        stateMachine.addView(loadingView, forState: "loading")

        let errorView = EmptyStateView.instantiateFromInterfaceBuilder()
        errorView.configure(heading: "Oops", description: "An error occurred, please try again :(")
        stateMachine.addView(errorView, forState: "error")
    }

    func render() {
        switch viewModel.state {
        case .loading, .idle:
            stateMachine.transitionToState(.view("loading"), animated: false, completion: nil)

        case .success(let data):
            secretLabel.text = data
            stateMachine.transitionToState(.none)

        case .failure:
            stateMachine.transitionToState(.view("error"), animated: false, completion: nil)
        }
    }

    @IBAction func copyButtonTapped(_ sender: Any) {
        switch viewModel.state {
        case .success(data: let data):
            let pasteboard = UIPasteboard.general
            pasteboard.string = data

            copyButton.setTitle("Copied!", for: .normal)
            Utils.delayWithSeconds(1) {
                self.copyButton.setTitle("Copy", for: .normal)
            }

        default:
            return
        }
    }

    @IBAction func nextButtonTapped(_ sender: Any) {
        performSegue(withIdentifier: "toEnterCodeVC", sender: nil)
    }

    @IBAction func closeButtonTapped(_ sender: Any) {
        dismiss(animated: true)
    }
}

extension EnableTwoFactorSecretViewController: EnableTwoFactorSecretViewModelDelegate {
    func stateChanged() {
        render()
    }
}
