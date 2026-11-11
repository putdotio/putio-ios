import SwiftUI

public enum PutioKaomoji: String, CaseIterable, Sendable {
  case shrug = "¯\\_(ツ)_/¯"
  case knockedOut = "(×_×)"
}

public enum PutioScreenErrorKind: CaseIterable, Sendable {
  case failed
  case offline

  public var title: String {
    switch self {
    case .failed: String(localized: "Couldn’t load this", bundle: .module)
    case .offline: String(localized: "put.io is out of reach", bundle: .module)
    }
  }

  public var message: String {
    switch self {
    case .failed:
      String(localized: "Check your connection and try again.", bundle: .module)
    case .offline:
      String(
        localized: "Your connection dropped, or we did. Retrying on its own.", bundle: .module)
    }
  }
}

public struct PutioLoadingStateView: View {
  private let title: String?
  private let titleVisibility: Visibility

  public init(title: String? = nil, titleVisibility: Visibility = .visible) {
    self.title = title
    self.titleVisibility = titleVisibility
  }

  public static var files: Self {
    Self(title: String(localized: "Loading files", bundle: .module), titleVisibility: .hidden)
  }

  public var body: some View {
    VStack(spacing: PutioScreenStateLayout.contentGap) {
      PutioScreenStateSpinner(
        accessibilityLabel: titleVisibility == .hidden ? title : nil
      )
      if let title, titleVisibility != .hidden {
        Text(title)
          .putioFont(PutioScreenStateLayout.messageFont)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct PutioScreenStateSpinner: View {
  let accessibilityLabel: String?

  var body: some View {
    let spinner = ProgressView()
      .controlSize(.large)
      .tint(PutioScreenStateLayout.spinnerTint)
    if let accessibilityLabel {
      spinner.accessibilityLabel(accessibilityLabel)
    } else {
      spinner
    }
  }
}

public struct PutioEmptyStateView: View {
  private enum Glyph {
    case icon(PutioIcon)
    case kaomoji(PutioKaomoji)
  }

  private let glyph: Glyph
  private let title: String
  private let message: String?
  private let action: PutioScreenStateAction?

  public init(
    icon: PutioIcon = .folderFill,
    title: String,
    message: String? = nil,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.glyph = .icon(icon)
    self.title = title
    self.message = message
    self.action = PutioScreenStateAction.optional(title: actionTitle, icon: nil, perform: action)
  }

  public init(
    kaomoji: PutioKaomoji,
    title: String,
    message: String? = nil,
    actionTitle: String? = nil,
    actionIcon: PutioIcon? = nil,
    action: (() -> Void)? = nil
  ) {
    self.glyph = .kaomoji(kaomoji)
    self.title = title
    self.message = message
    self.action = PutioScreenStateAction.optional(
      title: actionTitle, icon: actionIcon, perform: action)
  }

  public static func folder(createFolder: (() -> Void)? = nil) -> Self {
    Self(
      kaomoji: .shrug,
      title: String(localized: "No files whatsoever!", bundle: .module),
      message: String(localized: "Maybe you’d like to create a new folder?", bundle: .module),
      actionTitle: String(localized: "Create folder", bundle: .module),
      actionIcon: .folderSimplePlus,
      action: createFolder
    )
  }

  public static var history: Self {
    Self(
      kaomoji: .shrug,
      title: String(localized: "No history yet", bundle: .module),
      message: String(
        localized: "Completed transfers and shared files will appear here.", bundle: .module)
    )
  }

  public var body: some View {
    PutioScreenStateContent(title: title, message: message, action: action) {
      switch glyph {
      case .icon(let icon): PutioScreenStateIcon(icon: icon, tint: PutioTheme.Colors.textDisabled)
      case .kaomoji(let kaomoji): PutioScreenStateKaomoji(kaomoji: kaomoji)
      }
    }
  }
}

public struct PutioErrorStateView: View {
  private let title: String
  private let message: String?
  private let retry: PutioScreenStateAction?

  public init(
    title: String,
    message: String? = nil,
    retryTitle: String? = nil,
    retryIdentifier: String? = nil,
    retry: (() -> Void)? = nil
  ) {
    self.title = title
    self.message = message
    self.retry = PutioScreenStateAction.optional(
      title: retryTitle,
      icon: .arrowCounterClockwise,
      identifier: retryIdentifier,
      perform: retry
    )
  }

  public init(
    kind: PutioScreenErrorKind,
    retryIdentifier: String? = nil,
    retry: @escaping () -> Void
  ) {
    self.init(
      title: kind.title,
      message: kind.message,
      retryTitle: PutioScreenStateLayout.retryTitle,
      retryIdentifier: retryIdentifier,
      retry: retry
    )
  }

  public var body: some View {
    PutioScreenStateContent(title: title, message: message, action: retry) {
      #if os(tvOS)
        PutioScreenStateIcon(icon: .warningCircle, tint: PutioTheme.Colors.destructive)
      #else
        PutioScreenStateKaomoji(kaomoji: .knockedOut)
      #endif
    }
  }
}

#if !os(tvOS)
  public struct PutioOfflineBanner: View {
    @PutioScaledMetric private var iconSize: CGFloat
    @PutioScaledMetric private var contentGap: CGFloat

    public init() {
      _iconSize = PutioScaledMetric(PutioScreenStateLayout.bannerIconSize)
      _contentGap = PutioScaledMetric(PutioTheme.ScaledMetrics.contentGap)
    }

    public var body: some View {
      HStack(spacing: contentGap) {
        Image(putioIcon: .wifiSlash)
          .resizable()
          .scaledToFit()
          .frame(width: iconSize, height: iconSize)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityHidden(true)
        Text(String(localized: "Offline. Showing what’s on this iPhone.", bundle: .module))
          .putioFont(PutioScreenStateLayout.messageFont)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, PutioTheme.Spacing.space3)
      .padding(.vertical, PutioScreenStateLayout.bannerVerticalPadding)
      .background(
        PutioTheme.Colors.surface,
        in: RoundedRectangle(
          cornerRadius: PutioScreenStateLayout.bannerCornerRadius, style: .continuous)
      )
      .accessibilityElement(children: .combine)
    }
  }

  public struct PutioNextPageLoadingFooter: View {
    private let accessibilityLabel: String?

    public init(accessibilityLabel: String? = nil) {
      self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
      PutioScreenStateSpinner(accessibilityLabel: accessibilityLabel)
        .frame(maxWidth: .infinity)
        .padding(.vertical, PutioTheme.Spacing.space3)
    }
  }

  public struct PutioNextPageFailedFooter: View {
    private let message: String
    private let retryIdentifier: String?
    private let retry: () -> Void

    public init(message: String, retryIdentifier: String? = nil, retry: @escaping () -> Void) {
      self.message = message
      self.retryIdentifier = retryIdentifier
      self.retry = retry
    }

    public static func files(retryIdentifier: String? = nil, retry: @escaping () -> Void) -> Self {
      Self(
        message: String(localized: "Couldn’t load more files.", bundle: .module),
        retryIdentifier: retryIdentifier,
        retry: retry
      )
    }

    public var body: some View {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: PutioTheme.Spacing.space3) {
          messageText
          Spacer(minLength: 0)
          retryButton
        }
        VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
          messageText
          retryButton
        }
      }
      .padding(.horizontal, PutioTheme.Spacing.space3)
      .padding(.vertical, PutioTheme.Spacing.space2)
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var messageText: some View {
      Text(message)
        .putioFont(PutioScreenStateLayout.messageFont)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var retryButton: some View {
      PutioScreenStateButton(
        action: PutioScreenStateAction(
          title: PutioScreenStateLayout.retryTitle,
          icon: nil,
          identifier: retryIdentifier,
          perform: retry
        ),
        size: .medium
      )
    }
  }
#endif

private struct PutioScreenStateAction {
  let title: String
  let icon: PutioIcon?
  let identifier: String?
  let perform: () -> Void

  init(title: String, icon: PutioIcon?, identifier: String? = nil, perform: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.identifier = identifier
    self.perform = perform
  }

  static func optional(
    title: String?, icon: PutioIcon?, identifier: String? = nil, perform: (() -> Void)?
  ) -> Self? {
    guard let title, let perform else { return nil }
    return Self(title: title, icon: icon, identifier: identifier, perform: perform)
  }
}

private struct PutioScreenStateContent<Glyph: View>: View {
  let title: String
  let message: String?
  let action: PutioScreenStateAction?
  @ViewBuilder let glyph: Glyph

  var body: some View {
    ContentUnavailableView {
      Label {
        Text(title)
          .putioFont(PutioScreenStateLayout.titleFont)
          .putioScreenStateForeground(PutioTheme.Colors.textPrimary)
      } icon: {
        glyph
      }
    } description: {
      if let message {
        Text(message)
          .putioFont(PutioScreenStateLayout.messageFont)
          .putioScreenStateForeground(PutioTheme.Colors.textSecondary)
      }
    } actions: {
      if let action {
        PutioScreenStateButton(action: action, size: PutioScreenStateLayout.actionSize)
      }
    }
  }
}

private struct PutioScreenStateIcon: View {
  let icon: PutioIcon
  let tint: Color

  @PutioScaledMetric private var iconSize: CGFloat

  init(icon: PutioIcon, tint: Color) {
    self.icon = icon
    self.tint = tint
    _iconSize = PutioScaledMetric(PutioScreenStateLayout.iconSize)
  }

  var body: some View {
    Image(putioIcon: icon)
      .resizable()
      .scaledToFit()
      .frame(width: iconSize, height: iconSize)
      .foregroundStyle(tint)
  }
}

private struct PutioScreenStateKaomoji: View {
  let kaomoji: PutioKaomoji

  var body: some View {
    Text(verbatim: kaomoji.rawValue)
      .putioFont(PutioScreenStateLayout.kaomojiFont)
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .lineLimit(1)
      .fixedSize()
      .accessibilityHidden(true)
  }
}

private struct PutioScreenStateButton: View {
  let action: PutioScreenStateAction
  let size: PutioButtonSize

  #if !os(tvOS)
    @PutioScaledMetric private var contentGap: CGFloat
    @PutioScaledMetric private var iconSize: CGFloat
  #endif

  init(action: PutioScreenStateAction, size: PutioButtonSize) {
    self.action = action
    self.size = size
    #if !os(tvOS)
      _contentGap = PutioScaledMetric(PutioTheme.ScaledMetrics.buttonContentGap)
      _iconSize = PutioScaledMetric(PutioTheme.ScaledMetrics.buttonIconSize)
    #endif
  }

  var body: some View {
    #if os(tvOS)
      PutioButton(action.title, icon: action.icon, tier: .secondary, size: size) {
        action.perform()
      }
      .accessibilityIdentifier(action.identifier ?? "")
    #else
      Button(action: action.perform) {
        HStack(spacing: contentGap) {
          if let icon = action.icon {
            Image(putioIcon: icon)
              .resizable()
              .scaledToFit()
              .frame(width: iconSize, height: iconSize)
              .accessibilityHidden(true)
          }
          Text(action.title)
        }
        .putioFont(size.brandLabel)
      }
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .controlSize(size.controlSize)
      .tint(PutioTheme.Colors.textPrimary)
      .accessibilityIdentifier(action.identifier ?? "")
    #endif
  }
}

extension View {
  @ViewBuilder
  fileprivate func putioScreenStateForeground(_ color: Color) -> some View {
    #if os(tvOS)
      self
    #else
      foregroundStyle(color)
    #endif
  }

  // The content layer is opaque --app-bg, replacing systemBackground
  // (ios-s00): hide any system scroll background and paint the token so
  // hosted containers (TabView, List, Form) cannot bleed system black
  // through.
  @MainActor
  public func putioContentBackground() -> some View {
    #if os(tvOS)
      frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PutioTheme.Colors.background)
    #else
      scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PutioTheme.Colors.background)
    #endif
  }
}

enum PutioScreenStateLayout {
  static var retryTitle: String { String(localized: "Try again", bundle: .module) }

  #if os(tvOS)
    static let titleFont = PutioTheme.TV.Typography.label
    static let messageFont = PutioTheme.TV.Typography.body
    static let contentGap = PutioTheme.TV.Spacing.medium
    static let spinnerTint = PutioTheme.Colors.accent
    static let actionSize = PutioButtonSize.medium
    static let kaomojiFont = PutioTheme.TV.Typography.heading
    static let iconSize = PutioMetricRole(
      value: PutioTheme.TV.Typography.heading.size,
      relativeTo: .title
    )
  #else
    static let titleFont = PutioTheme.Typography.heading
    static let messageFont = PutioTheme.Typography.body
    static let kaomojiFont = PutioFontRole(
      fontName: PutioTheme.Typography.mono.fontName,
      size: PutioTheme.Typography.sizeXl,
      lineHeight: PutioTheme.Typography.mono.lineHeight,
      textStyle: .title
    )
    static let contentGap = PutioTheme.Spacing.space3
    static let spinnerTint = PutioTheme.Colors.textSecondary
    static let actionSize = PutioButtonSize.regular
    static let iconSize = PutioMetricRole(value: 52, relativeTo: .title)
    static let bannerIconSize = PutioMetricRole(
      value: PutioTheme.Typography.sizeMd, relativeTo: .body)
    static let bannerVerticalPadding = PutioTheme.Spacing.space2 + PutioTheme.Spacing.space1
    static let bannerCornerRadius = PutioTheme.Spacing.space3
  #endif
}
