import SwiftUI

public struct PutioSheetDismissButton: Sendable {
  public let title: String

  public init(title: String) {
    self.title = title
  }

  public static var cancel: PutioSheetDismissButton {
    PutioSheetDismissButton(title: String(localized: "Cancel", bundle: .module))
  }
}

public struct PutioSheetIconButton {
  public let icon: PutioIcon
  public let label: String
  public let action: @MainActor () -> Void

  public init(icon: PutioIcon, label: String, action: @escaping @MainActor () -> Void) {
    self.icon = icon
    self.label = label
    self.action = action
  }
}

public struct PutioSheetPrimaryButton {
  public let title: String
  public let isBusy: Bool
  public let isEnabled: Bool
  public let action: @MainActor () -> Void

  public init(
    _ title: String,
    isBusy: Bool = false,
    isEnabled: Bool = true,
    action: @escaping @MainActor () -> Void
  ) {
    self.title = title
    self.isBusy = isBusy
    self.isEnabled = isEnabled
    self.action = action
  }

  var acceptsTap: Bool {
    isEnabled && !isBusy
  }
}

public struct PutioSheetScaffold<Content: View>: View {
  private let title: String
  private let dismissButton: PutioSheetDismissButton?
  private let trailingButton: PutioSheetIconButton?
  private let primaryButton: PutioSheetPrimaryButton?
  private let content: Content

  #if os(iOS)
    @Environment(\.dismiss) private var dismiss
  #endif

  public init(
    title: String,
    dismissButton: PutioSheetDismissButton? = .cancel,
    trailingButton: PutioSheetIconButton? = nil,
    primaryButton: PutioSheetPrimaryButton? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.dismissButton = dismissButton
    self.trailingButton = trailingButton
    self.primaryButton = primaryButton
    self.content = content()
  }

  private var isBusy: Bool {
    primaryButton?.isBusy == true
  }

  public var body: some View {
    #if os(iOS)
      NavigationStack {
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .scrollContentBackground(.hidden)
          .background(PutioTheme.Components.Sheet.background)
          .navigationTitle(title)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar { titleBarButtons }
          .safeAreaInset(edge: .bottom, spacing: 0) {
            if let primaryButton {
              PutioSheetPrimaryBar(button: primaryButton)
            }
          }
      }
      .presentationDragIndicator(.visible)
      .presentationSizing(.form)
      .presentationBackground(PutioTheme.Components.Sheet.background)
      .interactiveDismissDisabled(isBusy)
    #elseif os(tvOS)
      VStack(spacing: 0) {
        titleRow
        Rectangle()
          .fill(PutioTheme.Components.Sheet.border)
          .frame(height: PutioTheme.Border.width)
        content
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(PutioSheetLayout.contentPadding)
        if let primaryButton {
          PutioButton(primaryButton.title, tier: .primary) {
            primaryButton.action()
          }
          .disabled(!primaryButton.acceptsTap)
          .padding(PutioSheetLayout.contentPadding)
        }
      }
      .background(
        PutioTheme.Components.Sheet.background,
        in: RoundedRectangle(cornerRadius: PutioTheme.TV.radius)
      )
      .interactiveDismissDisabled(isBusy)
    #else
      VStack(spacing: 0) {
        titleRow
        Divider()
        content
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(PutioSheetLayout.contentPadding)
        Spacer(minLength: 0)
        if let primaryButton {
          PutioSheetPrimaryBar(button: primaryButton)
        }
      }
      .interactiveDismissDisabled(isBusy)
    #endif
  }

  #if os(iOS)
    @ToolbarContentBuilder private var titleBarButtons: some ToolbarContent {
      if let dismissButton {
        ToolbarItem(placement: .cancellationAction) {
          Button(dismissButton.title) {
            dismiss()
          }
          .disabled(isBusy)
          .accessibilityIdentifier("sheet.dismiss")
        }
      }
      if let trailingButton {
        ToolbarItem(placement: .primaryAction) {
          Button {
            trailingButton.action()
          } label: {
            Label {
              Text(trailingButton.label)
            } icon: {
              Image(putioIcon: trailingButton.icon)
            }
          }
          .labelStyle(.iconOnly)
          .disabled(isBusy)
          .accessibilityIdentifier("sheet.trailing")
        }
      }
    }
  #else
    private var titleRow: some View {
      Text(title)
        .putioFont(PutioSheetLayout.titleFont)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .frame(maxWidth: .infinity, alignment: PutioSheetLayout.titleAlignment)
        .padding(PutioSheetLayout.contentPadding)
    }
  #endif
}

#if !os(tvOS)
  private struct PutioSheetPrimaryBar: View {
    let button: PutioSheetPrimaryButton

    var body: some View {
      Button {
        button.action()
      } label: {
        ZStack {
          Text(button.title)
            .opacity(button.isBusy ? 0 : 1)
          if button.isBusy {
            ProgressView()
              .tint(PutioTheme.Components.Button.primaryForeground)
          }
        }
        .putioFont(PutioButtonSize.regular.brandLabel)
        .foregroundStyle(PutioTheme.Components.Button.primaryForeground)
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .controlSize(.large)
      .tint(PutioTheme.Colors.accent)
      .disabled(!button.acceptsTap)
      .accessibilityLabel(button.title)
      .accessibilityIdentifier("sheet.primary")
      .padding(.horizontal, PutioSheetLayout.contentPadding)
      .padding(.vertical, PutioSheetLayout.primaryBarVerticalPadding)
    }
  }
#endif

enum PutioSheetLayout {
  #if os(tvOS)
    static let titleFont = PutioTheme.TV.Typography.label
    static let contentPadding = PutioTheme.TV.Spacing.medium
    static let titleAlignment = Alignment.leading
  #else
    static let contentPadding = PutioTheme.Spacing.space3
    static let primaryBarVerticalPadding = PutioTheme.Spacing.space2
  #endif
  #if !os(iOS) && !os(tvOS)
    static let titleFont = PutioTheme.Typography.subheading
    static let titleAlignment = Alignment.center
  #endif
}
