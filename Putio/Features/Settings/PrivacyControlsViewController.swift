import UIKit
import WebKit

class PrivacyControlsViewController: UITableViewController {
    static let privacyPolicyURL = ProductAnalyticsPromptViewController.privacyPolicyURL
    // Linked from the privacy policy as the list of services put.io uses.
    static let servicesWeUseURL = URL(string: "https://put.io/services-we-use?webview")!

    let viewModel: SettingsViewModel
    private(set) var sections: [SettingsModel.Section] = []

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        super.init(style: .grouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = NSLocalizedString("Privacy controls", comment: "")
        tableView.backgroundColor = UIColor.Putio.Surface.appBg
        tableView.contentInsetAdjustmentBehavior = .automatic
        viewModel.privacyControlsViewController = self
        reload()
    }

    func reload() {
        sections = viewModel.privacyControlsSections()
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    func presentWebPage(_ url: URL) {
        let controller = UIViewController()
        let webView = WKWebView(frame: controller.view.bounds)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.backgroundColor = UIColor.Putio.Surface.appBg
        webView.isOpaque = false
        webView.load(URLRequest(url: url))
        controller.view.addSubview(webView)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissWebPage)
        )
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    @objc private func dismissWebPage() {
        presentedViewController?.dismiss(animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].items.filter { $0.visible }.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        guard let footerView = view as? UITableViewHeaderFooterView else { return }
        footerView.textLabel?.textColor = UIColor.Putio.Neutral.textSecondary
        if let brandFont = BrandTypography.fontIfAvailable(.small) {
            footerView.textLabel?.font = brandFont
            footerView.textLabel?.adjustsFontForContentSizeCategory = true
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = sections[indexPath.section].items.filter { $0.visible }[indexPath.row]
        let cell = SettingsTableViewCell.dequeueSubtitleCell(from: tableView)
        cell.configure(with: item)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = sections[indexPath.section].items.filter { $0.visible }[indexPath.row]
        guard let action = item.action else { return }
        action()
    }
}

extension SettingsViewModel {
    // The descriptions and the group footer are contract copy, word for word.
    func privacyControlsSections() -> [SettingsModel.Section] {
        [
            SettingsModel.Section(
                title: "",
                items: [
                    SettingsModel.SectionItem(
                        title: NSLocalizedString("Strictly necessary", comment: ""),
                        type: .text,
                        icon: .lock,
                        value: NSLocalizedString("Always on", comment: ""),
                        action: nil,
                        visible: true,
                        subtitle: NSLocalizedString("Needed for sign-in, security, transfers, downloads, playback, billing, and saving your choices.", comment: "")
                    ),
                    SettingsModel.SectionItem(
                        title: NSLocalizedString("Diagnostics", comment: ""),
                        type: .toggle,
                        icon: .pulse,
                        value: settings.diagnosticsEnabled,
                        action: { self.saveDiagnosticsEnabled(!self.settings.diagnosticsEnabled) },
                        visible: true,
                        subtitle: NSLocalizedString("Crash reports, error details, and limited playback diagnostics, so we can fix problems.", comment: "")
                    ),
                    SettingsModel.SectionItem(
                        title: NSLocalizedString("Product analytics", comment: ""),
                        type: .toggle,
                        icon: .chartPie,
                        value: settings.productAnalyticsEnabled,
                        action: { self.saveProductAnalyticsEnabled(!self.settings.productAnalyticsEnabled) },
                        visible: true,
                        subtitle: NSLocalizedString("Limited usage, device, billing, and playback data that shows which apps and features work.", comment: "")
                    )
                ],
                footer: NSLocalizedString("Diagnostics and product analytics never send filenames, media titles, URLs, search text, or tokens.", comment: "")
            ),
            SettingsModel.Section(
                title: "",
                items: [
                    SettingsModel.SectionItem(
                        title: NSLocalizedString("Privacy policy", comment: ""),
                        type: .link,
                        icon: .file,
                        value: "",
                        action: { self.privacyControlsViewController?.presentWebPage(PrivacyControlsViewController.privacyPolicyURL) },
                        visible: true
                    ),
                    SettingsModel.SectionItem(
                        title: NSLocalizedString("Services we use", comment: ""),
                        type: .link,
                        icon: .info,
                        value: "",
                        action: { self.privacyControlsViewController?.presentWebPage(PrivacyControlsViewController.servicesWeUseURL) },
                        visible: true
                    )
                ]
            )
        ]
    }
}
