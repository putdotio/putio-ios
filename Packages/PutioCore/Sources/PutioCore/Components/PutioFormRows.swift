import SwiftUI

// Form primitives are native Form/List rows: the system owns the row chrome,
// insets, and Dynamic Type behavior; the kit adds brand type and token tints.
public struct PutioFormField: View {
  private let label: String
  private let placeholder: String
  private let errorText: String?
  @Binding private var text: String

  @PutioScaledMetric private var textGap: CGFloat

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
    _textGap = PutioScaledMetric(PutioTheme.ScaledMetrics.compactContentGap)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: textGap) {
      Text(label)
        .putioFont(PutioFormLayout.labelFont)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
      TextField(label, text: $text, prompt: Text(placeholder))
        .putioFont(PutioFormLayout.valueFont)
      // Invalid flips supporting text only; the row surface never fills red.
      if let errorText {
        Text(errorText)
          .putioFont(PutioFormLayout.labelFont)
          .foregroundStyle(PutioTheme.Colors.destructive)
      }
    }
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
      // watchOS has no menu picker either, so the row cycles there too.
      Button(action: selectNext) {
        HStack(spacing: PutioTheme.Spacing.space2) {
          PutioFormRowLabel(title: title, subtitle: nil)
          Spacer(minLength: PutioTheme.Spacing.space2)
          Text(optionLabel(selection))
            .putioFont(PutioFormLayout.valueFont)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
        }
      }
    #else
      Picker(selection: $selection) {
        ForEach(options, id: \.self) { option in
          Text(optionLabel(option)).tag(option)
        }
      } label: {
        PutioFormRowLabel(title: title, subtitle: nil)
      }
      .pickerStyle(.menu)
      .tint(PutioTheme.Colors.textSecondary)
    #endif
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
  }
}

enum PutioFormLayout {
  #if os(tvOS)
    static let titleFont = PutioTheme.TV.Typography.body
    static let valueFont = PutioTheme.TV.Typography.body
    static let labelFont = PutioTheme.TV.Typography.caption
  #else
    static let titleFont = PutioTheme.Typography.body
    static let valueFont = PutioTheme.Typography.body
    static let labelFont = PutioTheme.Typography.caption
  #endif
}
