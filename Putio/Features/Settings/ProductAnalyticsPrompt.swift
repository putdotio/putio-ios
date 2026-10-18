import UIKit
import WebKit
import PutioSDK

enum ProductAnalyticsChoice {
    typealias Request = (@escaping (Result<Void, PutioSDKError>) -> Void) -> Void
    typealias SaveSettingRequest = (Bool, @escaping (Result<Void, PutioSDKError>) -> Void) -> Void

    enum Failure: Error {
        case setting(PutioSDKError)
        case answer(PutioSDKError)
    }

    static let saveSettingRequest: SaveSettingRequest = { enabled, completion in
        api.saveAccountSettings(.patch(PutioAccountSettingsPatch(productAnalyticsEnabled: enabled))) {
            completion($0.map { _ in })
        }
    }

    static let markAnsweredRequest: Request = { completion in
        api.markProductAnalyticsPromptAnswered { completion($0.map { _ in }) }
    }

    /// Unset reads as off, so an account is asked until it turns analytics on
    /// or this app stores an answer. A launch that opens links skips the ask:
    /// DeeplinkManager dismisses whatever is presented, which could close the
    /// sheet mid-animation and lose the link, and the next launch asks anyway.
    static func shouldAsk(productAnalyticsEnabled: Bool, promptAnswered: Bool, opensLaunchLinks: Bool) -> Bool {
        !productAnalyticsEnabled && !promptAnswered && !opensLaunchLinks
    }

    /// The setting, then the prompt's answer, the order web writes them: a failed setting records no answer, and a save that lands after a sign-out applies to nobody.
    static func save(
        _ enabled: Bool,
        saveSetting: SaveSettingRequest,
        markAnswered: @escaping Request,
        completion: @escaping (Result<Void, Failure>) -> Void
    ) {
        let session = AccountNoticeStore.shared.session
        saveSetting(enabled) { result in
            switch result {
            case .failure(let error):
                completion(.failure(.setting(error)))
            case .success:
                if session == AccountNoticeStore.shared.session { settingDidSave(enabled: enabled) }
                markAnswered { completion($0.mapError(Failure.answer)) }
            }
        }
    }

    /// put.io now holds `enabled`. Both writers pass through here, so capture follows it and an older account read can't undo it.
    static func settingDidSave(enabled: Bool) {
        SettingsViewModel.confirmedSaves += 1
        ProductAnalytics.settingDidSave(enabled: enabled)
    }
}

/// Asks once whether the account allows product analytics. Closing it without
/// answering writes nothing, so the next launch asks again.
final class ProductAnalyticsPromptViewController: UIViewController {
    typealias StoreLocally = (Bool) -> Void

    static let privacyPolicyURL = URL(string: "https://put.io/privacy-policy/?webview")!

    private let saveSetting: ProductAnalyticsChoice.SaveSettingRequest
    private let markAnswered: ProductAnalyticsChoice.Request
    private let storeLocally: StoreLocally

    private(set) var isSaving = false

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let listsStack = UIStackView()
    private let buttonsStack = UIStackView()
    let errorLabel = UILabel()
    let denyButton = UIButton(type: .system)
    let allowButton = UIButton(type: .system)
    private let privacyPolicyButton = UIButton(type: .system)
    private var lastMeasuredHeight: CGFloat = 0

    private static let horizontalMargin: CGFloat = 20
    private static let topMargin: CGFloat = 28
    private static let bottomMargin: CGFloat = 16
    private static let formSheetWidth: CGFloat = 540

    init(
        saveSetting: @escaping ProductAnalyticsChoice.SaveSettingRequest = ProductAnalyticsChoice.saveSettingRequest,
        markAnswered: @escaping ProductAnalyticsChoice.Request = ProductAnalyticsChoice.markAnsweredRequest,
        storeLocally: @escaping StoreLocally = ProductAnalyticsPromptViewController.storeInRealm
    ) {
        self.saveSetting = saveSetting
        self.markAnswered = markAnswered
        self.storeLocally = storeLocally
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        configureSheet()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Settings observes this row, so an open Account tab follows the answer.
    static func storeInRealm(_ enabled: Bool) {
        guard let realm = PutioRealm.open(context: "ProductAnalyticsPrompt.storeInRealm"),
              let settings = realm.objects(User.self).first?.settings else { return }
        PutioRealm.write(realm, context: "ProductAnalyticsPrompt.storeInRealm.write") {
            settings.productAnalyticsEnabled = enabled
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Putio.Neutral.bgSecondary
        view.accessibilityIdentifier = "putio-product-analytics-prompt"
        buildLayout()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let isWide = view.bounds.width >= 500
        listsStack.axis = isWide ? .horizontal : .vertical
        listsStack.distribution = isWide ? .fillEqually : .fill
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = contentStack.frame.height + Self.topMargin + Self.bottomMargin
        guard abs(height - lastMeasuredHeight) > 0.5 else { return }
        lastMeasuredHeight = height
        preferredContentSize = CGSize(width: Self.formSheetWidth, height: height + view.safeAreaInsets.bottom)
        guard let sheet = sheetPresentationController else { return }
        if view.window == nil {
            sheet.invalidateDetents()
        } else {
            sheet.animateChanges { sheet.invalidateDetents() }
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard !isSaving else { return false }
        dismiss(animated: true)
        return true
    }

    func answer(_ enabled: Bool) {
        guard !isSaving else { return }
        setSaving(true, enabled: enabled)

        ProductAnalyticsChoice.save(enabled, saveSetting: saveSetting, markAnswered: markAnswered) { result in
            switch result {
            case .success:
                self.storeLocally(enabled)
                self.setSaving(false, enabled: enabled)
                // Through the presenter, so a privacy policy opened during the
                // save closes with the sheet instead of in its place.
                self.presentingViewController?.dismiss(animated: true)

            case .failure(.answer(let error)):
                // put.io holds the setting, so the local copy follows it; a
                // retry sends both again.
                self.storeLocally(enabled)
                self.setSaving(false, enabled: enabled)
                self.showError(error)

            case .failure(.setting(let error)):
                self.setSaving(false, enabled: enabled)
                self.showError(error)
            }
        }
    }

    private func configureSheet() {
        guard let sheet = sheetPresentationController else { return }
        sheet.prefersGrabberVisible = true
        sheet.detents = [
            .custom(identifier: .init("io.put.product-analytics-prompt")) { [weak self] context in
                guard let self, self.lastMeasuredHeight > 0 else { return context.maximumDetentValue }
                return min(self.lastMeasuredHeight, context.maximumDetentValue)
            }
        ]
    }

    private func setSaving(_ saving: Bool, enabled: Bool) {
        isSaving = saving
        isModalInPresentation = saving
        denyButton.isEnabled = !saving
        allowButton.isEnabled = !saving
        denyButton.configuration?.showsActivityIndicator = saving && !enabled
        allowButton.configuration?.showsActivityIndicator = saving && enabled
        if saving {
            errorLabel.isHidden = true
        }
    }

    private func showError(_ error: PutioErrorLocalizableInput) {
        let localizedError = api.localizeError(error: error)
        errorLabel.text = "\(localizedError.message)\n\(localizedError.recoverySuggestion.description)"
        errorLabel.applyBrandStyle(.small)
        errorLabel.isHidden = false
        UIAccessibility.post(notification: .layoutChanged, argument: errorLabel)
    }

    // MARK: - Layout

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        view.addSubview(scrollView)

        let titleLabel = makeLabel(
            NSLocalizedString("Turn on product analytics?", comment: ""),
            role: .h2,
            fallback: .title1,
            color: UIColor.Putio.Neutral.text
        )
        titleLabel.accessibilityTraits = .header

        let bodyLabel = makeLabel(
            NSLocalizedString("It helps us understand which apps and features work well. It stays off unless you allow it, and you can change it in Account → Privacy controls.", comment: ""),
            role: .body,
            fallback: .body,
            color: UIColor.Putio.Neutral.textSecondary
        )

        listsStack.spacing = 12
        listsStack.alignment = .fill
        listsStack.addArrangedSubview(makeList(
            title: NSLocalizedString("What we never send", comment: ""),
            items: [
                NSLocalizedString("Filenames or media titles", comment: ""),
                NSLocalizedString("URLs or search text", comment: ""),
                NSLocalizedString("Tokens", comment: "")
            ],
            icon: .xCircle,
            iconColor: UIColor.Putio.Red.solid,
            itemColor: UIColor.Putio.Neutral.textSecondary
        ))
        listsStack.addArrangedSubview(makeList(
            title: NSLocalizedString("What we'd send", comment: ""),
            items: [
                NSLocalizedString("Features you use", comment: ""),
                NSLocalizedString("App and device type", comment: ""),
                NSLocalizedString("Playback and billing events", comment: "")
            ],
            icon: .checkCircle,
            iconColor: UIColor.Putio.Green.solid,
            itemColor: UIColor.Putio.Neutral.text
        ))

        errorLabel.textColor = UIColor.Putio.Red.text
        errorLabel.numberOfLines = 0
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.isHidden = true

        configureAnswerButton(denyButton, title: NSLocalizedString("Don't allow", comment: ""), action: #selector(denyTapped))
        configureAnswerButton(allowButton, title: NSLocalizedString("Allow", comment: ""), action: #selector(allowTapped))
        buttonsStack.axis = .horizontal
        buttonsStack.distribution = .fillEqually
        buttonsStack.spacing = 8
        buttonsStack.addArrangedSubview(denyButton)
        buttonsStack.addArrangedSubview(allowButton)

        var linkConfiguration = UIButton.Configuration.plain()
        linkConfiguration.baseForegroundColor = UIColor.Putio.Neutral.textSecondary
        linkConfiguration.attributedTitle = AttributedString(
            NSLocalizedString("Privacy policy", comment: ""),
            attributes: AttributeContainer([
                .font: BrandTypography.fontIfAvailable(.small) ?? .preferredFont(forTextStyle: .footnote),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ])
        )
        privacyPolicyButton.configuration = linkConfiguration
        privacyPolicyButton.accessibilityTraits = .link
        privacyPolicyButton.addTarget(self, action: #selector(privacyPolicyTapped), for: .touchUpInside)

        [titleLabel, bodyLabel, listsStack, errorLabel, buttonsStack, privacyPolicyButton].forEach(contentStack.addArrangedSubview)
        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.setCustomSpacing(20, after: bodyLabel)
        contentStack.setCustomSpacing(20, after: listsStack)
        contentStack.setCustomSpacing(4, after: buttonsStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.topMargin),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.bottomMargin),
            contentStack.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: Self.horizontalMargin),
            contentStack.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -Self.horizontalMargin),

            denyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])
    }

    private func makeLabel(_ text: String, role: BrandTypography.Role, fallback: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = color
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: fallback)
        label.adjustsFontForContentSizeCategory = true
        label.applyBrandStyle(role)
        // The label role draws uppercase, which VoiceOver would read that way.
        label.accessibilityLabel = text
        return label
    }

    private func makeList(title: String, items: [String], icon: PutioIcon, iconColor: UIColor, itemColor: UIColor) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        let titleLabel = makeLabel(title, role: .label, fallback: .caption1, color: UIColor.Putio.Neutral.textSecondary)
        titleLabel.accessibilityTraits = .header
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(10, after: titleLabel)

        for item in items {
            let iconView = UIImageView(image: icon.image(for: .navigationList))
            iconView.tintColor = iconColor
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            iconView.isAccessibilityElement = false

            let row = UIStackView(arrangedSubviews: [iconView, makeLabel(item, role: .body, fallback: .body, color: itemColor)])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 8
            stack.addArrangedSubview(row)
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        let box = UIView()
        box.layer.borderWidth = 1
        box.layer.borderColor = UIColor.Putio.Neutral.line.cgColor
        box.layer.cornerRadius = 6
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14)
        ])
        return box
    }

    private func configureAnswerButton(_ button: UIButton, title: String, action: Selector) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseBackgroundColor = UIColor.Putio.Neutral.componentBg
        configuration.baseForegroundColor = UIColor.Putio.Neutral.text
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = BrandTypography.fontIfAvailable(.h4) ?? .preferredFont(forTextStyle: .headline)
            return outgoing
        }
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: - Actions

    @objc private func denyTapped() {
        answer(false)
    }

    @objc private func allowTapped() {
        answer(true)
    }

    @objc private func privacyPolicyTapped() {
        let controller = UIViewController()
        let webView = WKWebView(frame: controller.view.bounds)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.backgroundColor = UIColor.Putio.Surface.appBg
        webView.isOpaque = false
        webView.load(URLRequest(url: Self.privacyPolicyURL))
        controller.view.addSubview(webView)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissPrivacyPolicy)
        )
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    @objc private func dismissPrivacyPolicy() {
        presentedViewController?.dismiss(animated: true)
    }
}
