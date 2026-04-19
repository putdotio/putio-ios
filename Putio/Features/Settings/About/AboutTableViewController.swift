import UIKit
import WebKit
import VTAcknowledgementsViewController

class AboutTableViewController: UITableViewController {
    var webView: WKWebView!

    enum AboutItemKey: Int {
        case team, privacy, terms, licenses
    }

    struct AboutItem {
        var key: AboutItemKey
        var title: String
    }

    var items: [AboutItem] = [
        AboutItem(key: .team, title: NSLocalizedString("About put.io", comment: "")),
        AboutItem(key: .licenses, title: NSLocalizedString("Libraries we use in put.io iOS", comment: "")),
        AboutItem(key: .terms, title: NSLocalizedString("Terms of service", comment: "")),
        AboutItem(key: .privacy, title: NSLocalizedString("Privacy policy", comment: ""))
    ]

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "AboutListCell", for: indexPath)
        let item = items[indexPath.row]

        cell.textLabel?.text = item.title
        cell.accessoryType = .disclosureIndicator
        cell.accessoryView = UIImageView(image: UIImage(named: "chevronLeft")!)

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = items[indexPath.row]

        switch item.key {
        case .team:
            presentWebView(url: "https://put.io/about/?webview")
        case .privacy:
            presentWebView(url: "https://put.io/privacy-policy/?webview")
        case .terms:
            presentWebView(url: "https://put.io/terms-of-service/?webview")
        case .licenses:
            showLicenses()
        }

        tableView.deselectRow(at: indexPath, animated: false)
    }

    func presentWebView(url: String) {
        guard let url = URL(string: url) else { return }
        let myRequest = URLRequest(url: url)

        let controller = UIViewController()
        webView = WKWebView(frame: controller.view.bounds)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.backgroundColor = UIColor.Putio.background
        webView.isOpaque = false
        webView.load(myRequest)

        controller.view.addSubview(webView)

        let navController = UINavigationController(rootViewController: controller)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(self.dismissWebView)
        )

        present(navController, animated: true)
    }

    @objc func dismissWebView() {
        dismiss(animated: true)
    }

    func showLicenses() {
        let controller = VTAcknowledgementsViewController(fileNamed: "Pods-Putio-acknowledgements")

        controller.title = NSLocalizedString("Libraries we use in put.io iOS", comment: "")
        controller.headerText = ""
        controller.footerText = ""

        navigationController?.pushViewController(controller, animated: true)
    }
}
