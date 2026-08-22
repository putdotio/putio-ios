import SwiftUI

public struct PutioFormField: View {
  private let label: String
  private let placeholder: String
  private let errorText: String?
  @Binding private var text: String

  @Environment(\.isEnabled) private var isEnabled
  @FocusState private var isFocused: Bool

  public init(
    label: String,
    placeholder: String = "",
    text: Binding<String>,
    errorText: String? = nil
  ) {
    self.label = label
    self.placeholder = placeholder
    self.errorText = errorText
    _text = text
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
      Text(label)
        .putioFont(PutioFormLayout.labelFont)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
      TextField(
        label,
        text: $text,
        prompt: Text(placeholder)
          .foregroundStyle(PutioTheme.Components.Field.placeholder)
      )
      .textFieldStyle(.plain)
      .focused($isFocused)
      .putioFont(PutioFormLayout.valueFont)
      .foregroundStyle(
        isEnabled ? PutioTheme.Components.Field.text : PutioTheme.Colors.textSecondary
      )
      .padding(.horizontal, PutioFormLayout.fieldPaddingX)
      .padding(.vertical, PutioTheme.Spacing.space2)
      .background(
        isEnabled
          ? PutioTheme.Components.Field.background
          : PutioTheme.Components.Field.backgroundDisabled,
        in: PutioFormLayout.fieldShape
      )
      .overlay(
        PutioFormLayout.fieldShape.strokeBorder(borderColor, lineWidth: PutioTheme.Border.width)
      )
      if let errorText {
        Text(errorText)
          .putioFont(PutioFormLayout.labelFont)
          .foregroundStyle(PutioTheme.Colors.destructive)
      }
    }
  }

  // Invalid flips border and text only; the surface never fills red.
  private var borderColor: Color {
    if errorText != nil { return PutioTheme.Colors.destructive }
    if isFocused { return PutioTheme.Components.Field.borderFocus }
    return PutioTheme.Components.Field.border
  }
}

public struct PutioToggleRow: View {
  private let title: String
  private let subtitle: String?
  @Binding private var isOn: Bool

  public init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
    self.title = title
    self.subtitle = subtitle
    _isOn = isOn
  }

  public var body: some View {
    Toggle(isOn: $isOn) {
      PutioFormRowLabel(title: title, subtitle: subtitle)
    }
    .tint(PutioTheme.Colors.success)
    .padding(.vertical, PutioTheme.Spacing.space2)
  }
}

public struct PutioPickerRow<Option: Hashable>: View {
  private let title: String
  private let options: [Option]
  private let optionLabel: (Option) -> String
  @Binding private var selection: Option

  public init(
    title: String,
    selection: Binding<Option>,
    options: [Option],
    optionLabel: @escaping (Option) -> String
  ) {
    self.title = title
    self.options = options
    self.optionLabel = optionLabel
    _selection = selection
  }

  public var body: some View {
    #if os(tvOS) || os(watchOS)
      // The 10-foot pattern: the row is one focusable target that cycles
      // through its options; menus would be centered modals, not popovers.
      // watchOS has no Menu either, so the row cycles there too.
      Button(action: selectNext) {
        row
      }
      .buttonStyle(PutioListRowButtonStyle())
    #else
      Menu {
        Picker(title, selection: $selection) {
          ForEach(options, id: \.self) { option in
            Text(optionLabel(option)).tag(option)
          }
        }
      } label: {
        row
      }
      .buttonStyle(.plain)
    #endif
  }

  private var row: some View {
    HStack(spacing: PutioTheme.Spacing.space2) {
      PutioFormRowLabel(title: title, subtitle: nil)
      Spacer(minLength: PutioTheme.Spacing.space2)
      Text(optionLabel(selection))
        .putioFont(PutioFormLayout.valueFont)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
      PutioIconView(.caretRight, size: PutioFormLayout.caretSize)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
    }
    .padding(.vertical, PutioTheme.Spacing.space2)
  }

  private func selectNext() {
    guard let index = options.firstIndex(of: selection) else {
      if let first = options.first { selection = first }
      return
    }
    selection = options[(index + 1) % options.count]
  }
}

private struct PutioFormRowLabel: View {
  let title: String
  let subtitle: String?

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
      Text(title)
        .putioFont(PutioFormLayout.titleFont)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
      if let subtitle {
        Text(subtitle)
          .putioFont(PutioFormLayout.labelFont)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

enum PutioFormLayout {
  #if os(tvOS)
    static let titleFont = PutioTheme.TV.Typography.body
    static let valueFont = PutioTheme.TV.Typography.body
    static let labelFont = PutioTheme.TV.Typography.caption
    static let fieldPaddingX = PutioTheme.TV.Spacing.small
    static let caretSize = PutioMetricRole(value: PutioTheme.TV.Spacing.small, relativeTo: .body)
    static let fieldShape = RoundedRectangle(cornerRadius: PutioTheme.TV.radius)
  #else
    static let titleFont = PutioTheme.Typography.body
    static let valueFont = PutioTheme.Typography.body
    static let labelFont = PutioTheme.Typography.caption
    static let fieldPaddingX = PutioTheme.Spacing.space3
    static let caretSize = PutioMetricRole(value: PutioTheme.Typography.sizeBase, relativeTo: .body)
    static let fieldShape = RoundedRectangle(cornerRadius: PutioTheme.Radius.standard)
  #endif
}
