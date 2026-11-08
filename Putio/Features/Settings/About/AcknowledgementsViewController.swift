import UIKit

struct Acknowledgement: Decodable {
    let title: String
    let license: String

    static func bundled() -> [Acknowledgement] {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "plist") else {
            InternalFailurePresenter.log("Acknowledgements.plist is missing from the app bundle", context: "Acknowledgement.bundled.missing")
            return []
        }
        do {
            return try PropertyListDecoder().decode([Acknowledgement].self, from: Data(contentsOf: url))
        } catch {
            InternalFailurePresenter.log("Acknowledgements.plist did not decode: \(error.localizedDescription)", context: "Acknowledgement.bundled.decode")
            return []
        }
    }
}

final class AcknowledgementsViewController: UITableViewController {
    private static let cellIdentifier = "AcknowledgementCell"

    private let acknowledgements = Acknowledgement.bundled()

    init() {
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = NSLocalizedString("Libraries we use in put.io iOS", comment: "")
        tableView.backgroundColor = UIColor.Putio.Surface.appBg
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellIdentifier)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        acknowledgements.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        cell.backgroundColor = UIColor.Putio.Surface.appBg
        cell.textLabel?.text = acknowledgements[indexPath.row].title
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.textColor = UIColor.Putio.Neutral.text
        let accessoryImageView = UIImageView(image: PutioIcon.caretRight.image(pointSize: 16, scaledFor: tableView.traitCollection))
        accessoryImageView.tintColor = UIColor.Putio.Yellow.textSecondary
        cell.accessoryView = accessoryImageView
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let controller = AcknowledgementLicenseViewController(acknowledgement: acknowledgements[indexPath.row])
        navigationController?.pushViewController(controller, animated: true)
    }
}

private final class AcknowledgementLicenseViewController: UIViewController {
    private let acknowledgement: Acknowledgement

    init(acknowledgement: Acknowledgement) {
        self.acknowledgement = acknowledgement
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = acknowledgement.title
        view.backgroundColor = UIColor.Putio.Surface.appBg

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.dataDetectorTypes = .link
        textView.backgroundColor = .clear
        textView.textColor = UIColor.Putio.Neutral.text
        textView.font = .preferredFont(forTextStyle: .footnote)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.text = acknowledgement.license
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        ])
    }
}
