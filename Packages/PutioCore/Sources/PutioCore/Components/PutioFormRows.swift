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

public typealias PutioSettingSave<Value> = @MainActor (Value) async throws -> Void

public enum PutioSettingValueStyle: Sendable {
  case text
  case measurement
}

public struct PutioSettingsSection<Content: View>: View {
  private let title: String?
  private let footer: String?
  private let content: Content

  public init(
    _ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  public var body: some View {
    Group(subviews: content) { rows in
      if !rows.isEmpty {
        if let footer {
          Section {
            content
          } header: {
            header
          } footer: {
            Text(footer)
              .putioFont(PutioFormLayout.labelFont)
              .foregroundStyle(PutioTheme.Colors.textSecondary)
          }
        } else {
          Section {
            content
          } header: {
            header
          }
        }
      }
    }
  }

  @ViewBuilder private var header: some View {
    if let title {
      Text(title)
        .putioFont(PutioFormLayout.labelFont)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .textCase(nil)
    }
  }
}

public struct PutioNavigationRow<Destination: View>: View {
  private let title: String
  private let subtitle: String?
  private let icon: PutioIcon?
  private let value: String?
  private let valueStyle: PutioSettingValueStyle
  private let destination: Destination

  public init(
    _ title: String,
    subtitle: String? = nil,
    icon: PutioIcon? = nil,
    value: String? = nil,
    valueStyle: PutioSettingValueStyle = .text,
    @ViewBuilder destination: () -> Destination
  ) {
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.value = value
    self.valueStyle = valueStyle
    self.destination = destination()
  }

  public var body: some View {
    NavigationLink {
      destination
    } label: {
      PutioSettingsValueLayout(
        title: title, subtitle: subtitle, icon: icon, value: value, valueStyle: valueStyle)
    }
  }
}

public struct PutioNavigationValueRow<Value: Hashable>: View {
  private let title: String
  private let subtitle: String?
  private let icon: PutioIcon?
  private let value: String?
  private let valueStyle: PutioSettingValueStyle
  private let destination: Value
  @Environment(\.putioListDetailOpen) private var open

  public init(
    _ title: String,
    subtitle: String? = nil,
    icon: PutioIcon? = nil,
    value: String? = nil,
    valueStyle: PutioSettingValueStyle = .text,
    destination: Value
  ) {
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.value = value
    self.valueStyle = valueStyle
    self.destination = destination
  }

  public var body: some View {
    if let open {
      Button {
        open(AnyHashable(destination))
      } label: {
        HStack(spacing: PutioTheme.Spacing.space2) {
          PutioSettingsValueLayout(
            title: title, subtitle: subtitle, icon: icon, value: value, valueStyle: valueStyle
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          PutioIconView(.caretRight, size: PutioSettingsLayout.accessorySize)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
    } else {
      NavigationLink(value: destination) {
        PutioSettingsValueLayout(
          title: title, subtitle: subtitle, icon: icon, value: value, valueStyle: valueStyle)
      }
    }
  }
}

public struct PutioListDetailOpenAction: Sendable {
  private let action: @MainActor @Sendable (AnyHashable) -> Void

  public init(_ action: @escaping @MainActor @Sendable (AnyHashable) -> Void) {
    self.action = action
  }

  @MainActor public func callAsFunction(_ item: AnyHashable) {
    action(item)
  }
}

extension EnvironmentValues {
  @Entry public var putioListDetailOpen: PutioListDetailOpenAction? = nil
}

public struct PutioValueRow: View {
  private let title: String
  private let subtitle: String?
  private let icon: PutioIcon?
  private let value: String
  private let valueStyle: PutioSettingValueStyle

  public init(
    _ title: String,
    subtitle: String? = nil,
    icon: PutioIcon? = nil,
    value: String,
    valueStyle: PutioSettingValueStyle = .text
  ) {
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.value = value
    self.valueStyle = valueStyle
  }

  public var body: some View {
    PutioSettingsValueLayout(
      title: title, subtitle: subtitle, icon: icon, value: value, valueStyle: valueStyle
    )
    .accessibilityElement(children: .combine)
  }
}

public struct PutioLinkRow: View {
  private let title: String
  private let icon: PutioIcon?
  private let value: String?
  private let action: () -> Void

  public init(
    _ title: String, icon: PutioIcon? = nil, value: String? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.icon = icon
    self.value = value
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: PutioTheme.Spacing.space2) {
        PutioSettingsValueLayout(
          title: title, subtitle: nil, icon: icon, value: value, valueStyle: .text
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        PutioIconView(.arrowSquareOut, size: PutioSettingsLayout.accessorySize)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .accessibilityAddTraits(.isLink)
  }
}

public struct PutioToggleRow: View {
  private let title: String
  private let subtitle: String?
  private let icon: PutioIcon?
  private let source: PutioSettingSource<Bool>

  public init(
    title: String,
    subtitle: String? = nil,
    icon: PutioIcon? = nil,
    isOn: Binding<Bool>
  ) {
    self.init(title: title, subtitle: subtitle, icon: icon, source: .bound(isOn))
  }

  public init(
    _ title: String,
    icon: PutioIcon? = nil,
    isOn: Bool,
    save: @escaping PutioSettingSave<Bool>
  ) {
    self.init(title: title, subtitle: nil, icon: icon, source: .saved(isOn, pending: nil, save))
  }

  init(
    title: String,
    subtitle: String?,
    icon: PutioIcon?,
    source: PutioSettingSource<Bool>
  ) {
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.source = source
  }

  public var body: some View {
    PutioSettingField(source: source) { isOn in
      Toggle(isOn: isOn) {
        PutioSettingsLabel(title: title, subtitle: subtitle, icon: icon)
      }
      .putioSwitchTint()
    }
  }
}

public struct PutioPickerRow<Option: Hashable>: View {
  private let title: String
  private let icon: PutioIcon?
  private let options: [Option]
  private let optionLabel: (Option) -> String
  private let source: PutioSettingSource<Option>

  public init(
    title: String,
    icon: PutioIcon? = nil,
    selection: Binding<Option>,
    options: [Option],
    optionLabel: @escaping (Option) -> String
  ) {
    self.init(
      title: title, icon: icon, source: .bound(selection), options: options,
      optionLabel: optionLabel)
  }

  public init(
    _ title: String,
    icon: PutioIcon? = nil,
    selection: Option,
    options: [Option],
    save: @escaping PutioSettingSave<Option>,
    optionLabel: @escaping (Option) -> String
  ) {
    self.init(
      title: title, icon: icon, source: .saved(selection, pending: nil, save), options: options,
      optionLabel: optionLabel)
  }

  init(
    title: String,
    icon: PutioIcon?,
    source: PutioSettingSource<Option>,
    options: [Option],
    optionLabel: @escaping (Option) -> String
  ) {
    self.title = title
    self.icon = icon
    self.source = source
    self.options = options
    self.optionLabel = optionLabel
  }

  public var body: some View {
    PutioSettingField(source: source) { selection in
      picker(selection: selection)
    }
  }

  @ViewBuilder private func picker(selection: Binding<Option>) -> some View {
    #if os(tvOS) || os(watchOS)
      // The 10-foot pattern: the row is one focusable target that cycles
      // through its options; menus would be centered modals, not popovers.
      // watchOS has no menu picker either, so the row cycles there too.
      Button {
        selection.wrappedValue = next(after: selection.wrappedValue)
      } label: {
        HStack(spacing: PutioTheme.Spacing.space2) {
          PutioSettingsLabel(title: title, subtitle: nil, icon: icon)
          Spacer(minLength: PutioTheme.Spacing.space2)
          Text(optionLabel(selection.wrappedValue))
            .putioFont(PutioFormLayout.valueFont)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
        }
      }
    #else
      Picker(selection: selection) {
        ForEach(options, id: \.self) { option in
          Text(optionLabel(option)).tag(option)
        }
      } label: {
        PutioSettingsLabel(title: title, subtitle: nil, icon: icon)
      }
      .pickerStyle(.menu)
      .tint(PutioTheme.Colors.textSecondary)
    #endif
  }

  private func next(after current: Option) -> Option {
    guard let index = options.firstIndex(of: current) else {
      return options.first ?? current
    }
    return options[(index + 1) % options.count]
  }
}

#if os(iOS)
  public struct PutioMenuRow<Value: Equatable, Items: View>: View {
    private let title: String
    private let icon: PutioIcon?
    private let source: PutioSettingSource<Value>
    private let valueLabel: (Value) -> String
    private let items: (Binding<Value>) -> Items

    public init(
      _ title: String,
      icon: PutioIcon? = nil,
      selection: Value,
      save: @escaping PutioSettingSave<Value>,
      valueLabel: @escaping (Value) -> String,
      @ViewBuilder items: @escaping (Binding<Value>) -> Items
    ) {
      self.title = title
      self.icon = icon
      self.source = .saved(selection, pending: nil, save)
      self.valueLabel = valueLabel
      self.items = items
    }

    public var body: some View {
      PutioSettingField(source: source) { selection in
        Menu {
          items(selection)
        } label: {
          PutioMenuRowLabel(title: title, icon: icon, value: valueLabel(selection.wrappedValue))
        }
      }
    }
  }

  private struct PutioMenuRowLabel: View {
    let title: String
    let icon: PutioIcon?
    let value: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
      HStack(spacing: PutioTheme.Spacing.space2) {
        PutioSettingsLabel(title: title, subtitle: nil, icon: icon)
          .layoutPriority(1)
        Spacer(minLength: PutioTheme.Spacing.space2)
        HStack(spacing: PutioTheme.Spacing.space1) {
          Text(value)
            .putioFont(PutioFormLayout.valueFont)
            .multilineTextAlignment(.trailing)
          Image(systemName: "chevron.up.chevron.down")
            .imageScale(.small)
            .accessibilityHidden(true)
        }
        .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
      .opacity(isEnabled ? 1 : PutioDisabledRole.opacity)
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
    }
  }
#endif

public struct PutioChoice: Sendable, Equatable {
  public let title: String
  public let description: String?

  public init(_ title: String, description: String? = nil) {
    self.title = title
    self.description = description
  }
}

public struct PutioChoiceList<Option: Hashable>: View {
  private let options: [Option]
  private let choice: (Option) -> PutioChoice
  private let source: PutioSettingSource<Option>

  public init(
    selection: Binding<Option>,
    options: [Option],
    choice: @escaping (Option) -> PutioChoice
  ) {
    self.init(source: .bound(selection), options: options, choice: choice)
  }

  public init(
    selection: Option,
    options: [Option],
    save: @escaping PutioSettingSave<Option>,
    choice: @escaping (Option) -> PutioChoice
  ) {
    self.init(source: .saved(selection, pending: nil, save), options: options, choice: choice)
  }

  init(
    source: PutioSettingSource<Option>,
    options: [Option],
    choice: @escaping (Option) -> PutioChoice
  ) {
    self.source = source
    self.options = options
    self.choice = choice
  }

  public var body: some View {
    PutioSettingField(source: source) { selection in
      ForEach(options, id: \.self) { option in
        PutioChoiceRow(
          choice: choice(option),
          isSelected: option == selection.wrappedValue
        ) {
          selection.wrappedValue = option
        }
      }
    }
  }
}

private struct PutioChoiceRow: View {
  let choice: PutioChoice
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(spacing: PutioTheme.Spacing.space2) {
        PutioSettingsLabel(title: choice.title, subtitle: choice.description, icon: nil)
          .frame(maxWidth: .infinity, alignment: .leading)
        if isSelected {
          Image(systemName: "checkmark")
            .foregroundStyle(PutioTheme.Colors.textPrimary)
            .accessibilityHidden(true)
        }
      }
      .contentShape(Rectangle())
    }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

public struct PutioCheckRow: View {
  private let title: String
  private let icon: PutioIcon?
  private let isChecked: Bool
  private let toggle: () -> Void
  @Environment(\.isEnabled) private var isEnabled

  public init(
    _ title: String, icon: PutioIcon? = nil, isChecked: Bool, toggle: @escaping () -> Void
  ) {
    self.title = title
    self.icon = icon
    self.isChecked = isChecked
    self.toggle = toggle
  }

  public var body: some View {
    Button(action: toggle) {
      HStack(spacing: PutioTheme.Spacing.space2) {
        PutioSettingsLabel(title: title, subtitle: nil, icon: icon)
          .frame(maxWidth: .infinity, alignment: .leading)
        if isChecked {
          Image(systemName: "checkmark")
            .foregroundStyle(PutioTheme.Colors.textPrimary)
            .accessibilityHidden(true)
        }
      }
      .opacity(isEnabled ? 1 : PutioDisabledRole.opacity)
      .contentShape(Rectangle())
    }
    .accessibilityAddTraits(isChecked ? .isSelected : [])
  }
}

public struct PutioActionRow: View {
  private let title: String
  private let icon: PutioIcon?
  private let action: () -> Void

  public init(_ title: String, icon: PutioIcon? = nil, action: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      PutioSettingsLabel(title: title, subtitle: nil, icon: icon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
  }
}

public struct PutioDestructiveRow: View {
  private let title: String
  private let alignment: Alignment
  private let isBusy: Bool
  private let action: () -> Void
  @Environment(\.isEnabled) private var isEnabled

  public init(
    _ title: String, alignment: Alignment = .leading, isBusy: Bool = false,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.alignment = alignment
    self.isBusy = isBusy
    self.action = action
  }

  public var body: some View {
    Button(role: .destructive, action: action) {
      ZStack(alignment: alignment) {
        Text(title)
          .putioFont(PutioFormLayout.titleFont)
          .foregroundStyle(PutioTheme.Colors.destructive)
          .opacity(isBusy ? 0 : isEnabled ? 1 : PutioDisabledRole.opacity)
        if isBusy {
          ProgressView()
            .tint(PutioTheme.Colors.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: alignment)
      .contentShape(Rectangle())
    }
    .disabled(isBusy)
    .accessibilityLabel(title)
  }
}

public struct PutioSettingsLoadingRow: View {
  private let title: String

  public init(_ title: String) {
    self.title = title
  }

  public var body: some View {
    HStack(spacing: PutioSettingsLayout.iconGap) {
      ProgressView()
        .tint(PutioTheme.Colors.textSecondary)
      Text(title)
        .putioFont(PutioFormLayout.titleFont)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
    }
    .accessibilityElement(children: .combine)
  }
}

public struct PutioSettingsFailedRows: View {
  private let title: String
  private let identifier: String
  private let retryIdentifier: String
  private let retry: () -> Void

  public init(
    _ title: String, identifier: String, retryIdentifier: String, retry: @escaping () -> Void
  ) {
    self.title = title
    self.identifier = identifier
    self.retryIdentifier = retryIdentifier
    self.retry = retry
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: PutioSettingsLayout.iconGap) {
      PutioIconView(.warningCircle, size: PutioSettingsLayout.iconSize)
        .foregroundStyle(PutioTheme.Colors.destructive)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
        Text(title)
          .putioFont(PutioFormLayout.titleFont)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
        Text(PutioScreenErrorKind.failed.message)
          .putioFont(PutioFormLayout.labelFont)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
      .modifier(PutioSettingsSeparatorLeading())
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier)
    Button(action: retry) {
      Text(String(localized: "Try again", bundle: .module))
        .putioFont(PutioFormLayout.titleFont)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
    .accessibilityIdentifier(retryIdentifier)
  }
}

extension View {
  public func putioSettingSaveFailures() -> some View {
    modifier(PutioOwnedSettingSaveFailurePresenter())
  }

  public func putioSettingSaveFailures(_ failures: PutioSettingSaveFailures) -> some View {
    modifier(PutioSettingSaveFailurePresenter(failures: failures))
  }
}

public struct PutioSettingNotSaved: Error, Sendable {
  public init() {}
}

@MainActor @Observable
public final class PutioSettingSaveFailures {
  var toast: PutioToast?

  public init() {}

  static var failureToast: PutioToast {
    PutioToast(
      String(localized: "Couldn’t save this setting", bundle: .module), icon: .warning, width: .fit)
  }

  public func report() {
    toast = Self.failureToast
  }
}

extension EnvironmentValues {
  @Entry var putioSettingSaveFailures: PutioSettingSaveFailures? = nil
}

private struct PutioOwnedSettingSaveFailurePresenter: ViewModifier {
  @State private var failures = PutioSettingSaveFailures()

  func body(content: Content) -> some View {
    content.modifier(PutioSettingSaveFailurePresenter(failures: failures))
  }
}

private struct PutioSettingSaveFailurePresenter: ViewModifier {
  let failures: PutioSettingSaveFailures

  func body(content: Content) -> some View {
    @Bindable var presented = failures
    content
      .environment(\.putioSettingSaveFailures, failures)
      .putioToast($presented.toast)
  }
}

struct PutioPendingSetting<Value: Equatable>: Equatable {
  private(set) var value: Value?

  init(_ value: Value? = nil) {
    self.value = value
  }

  var isSaving: Bool { value != nil }

  func shown(over saved: Value) -> Value {
    value ?? saved
  }

  mutating func begin(_ next: Value, over saved: Value) -> Bool {
    guard value == nil, next != saved else { return false }
    value = next
    return true
  }

  mutating func end() {
    value = nil
  }
}

enum PutioSettingSource<Value: Equatable> {
  case bound(Binding<Value>)
  case saved(Value, pending: Value?, PutioSettingSave<Value>)
}

private struct PutioSettingField<Value: Equatable, Content: View>: View {
  let source: PutioSettingSource<Value>
  @ViewBuilder let content: (Binding<Value>) -> Content

  var body: some View {
    switch source {
    case .bound(let binding):
      content(binding)
    case .saved(let value, let pending, let save):
      PutioSavingSetting(value: value, pending: pending, save: save, content: content)
    }
  }
}

private struct PutioSavingSetting<Value: Equatable, Content: View>: View {
  let value: Value
  let save: PutioSettingSave<Value>
  let content: (Binding<Value>) -> Content
  @State private var pending: PutioPendingSetting<Value>
  @Environment(\.putioSettingSaveFailures) private var failures

  init(
    value: Value,
    pending: Value?,
    save: @escaping PutioSettingSave<Value>,
    content: @escaping (Binding<Value>) -> Content
  ) {
    self.value = value
    self.save = save
    self.content = content
    _pending = State(initialValue: PutioPendingSetting(pending))
  }

  var body: some View {
    content(Binding(get: { pending.shown(over: value) }, set: { commit($0) }))
      .disabled(pending.isSaving)
  }

  private func commit(_ next: Value) {
    guard pending.begin(next, over: value) else { return }
    Task { await run(next) }
  }

  private func run(_ next: Value) async {
    do {
      try await save(next)
    } catch is CancellationError {
    } catch {
      failures?.report()
    }
    pending.end()
  }
}

private struct PutioSettingsLabel: View {
  let title: String
  let subtitle: String?
  let icon: PutioIcon?

  var body: some View {
    HStack(spacing: PutioSettingsLayout.iconGap) {
      if let icon {
        PutioIconView(icon, size: PutioSettingsLayout.iconSize)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityHidden(true)
      }
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
    .modifier(PutioSettingsSeparatorLeading())
  }
}

private struct PutioSettingsValueLayout: View {
  let title: String
  let subtitle: String?
  let icon: PutioIcon?
  let value: String?
  let valueStyle: PutioSettingValueStyle
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    if let value, subtitle != nil {
      describedLayout {
        PutioSettingsLabel(title: title, subtitle: subtitle, icon: icon)
          .frame(maxWidth: .infinity, alignment: .leading)
        valueText(value)
          .fixedSize()
      }
    } else if let value {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: PutioTheme.Spacing.space2) {
          PutioSettingsLabel(title: title, subtitle: subtitle, icon: icon)
            .fixedSize()
          Spacer(minLength: PutioTheme.Spacing.space2)
          valueText(value)
            .fixedSize()
        }
        VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
          PutioSettingsLabel(title: title, subtitle: subtitle, icon: icon)
          valueText(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      PutioSettingsLabel(title: title, subtitle: subtitle, icon: icon)
    }
  }

  private var describedLayout: AnyLayout {
    dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: PutioTheme.Spacing.space1))
      : AnyLayout(HStackLayout(spacing: PutioTheme.Spacing.space2))
  }

  @ViewBuilder private func valueText(_ value: String) -> some View {
    switch valueStyle {
    case .text:
      Text(value)
        .putioFont(PutioFormLayout.labelFont)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
    case .measurement:
      Text(value)
        .putioFont(PutioSettingsLayout.measurementFont)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
    }
  }
}

private struct PutioSettingsSeparatorLeading: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
      content.alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    #else
      content
    #endif
  }
}

extension View {
  public func putioSwitchTint() -> some View {
    modifier(PutioNeutralSwitchTint())
  }
}

private struct PutioNeutralSwitchTint: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
      content.tint(.green)
    #else
      content
    #endif
  }
}

enum PutioSettingsLayout {
  static let iconGap = PutioTheme.Spacing.space3
  #if os(tvOS)
    static let iconSize = PutioMetricRole(
      value: PutioTheme.TV.Typography.label.size,
      relativeTo: .body
    )
    static let accessorySize = iconSize
    static let measurementFont = PutioTheme.TV.Typography.numeric
  #else
    static let iconSize = PutioMetricRole(
      value: PutioTheme.Typography.sizeMd,
      relativeTo: .body
    )
    static let accessorySize = PutioMetricRole(
      value: PutioTheme.Typography.sizeSm,
      relativeTo: .body
    )
    #if os(iOS) || os(watchOS)
      static let measurementFont = PutioTheme.Typography.numeric
    #else
      static let measurementFont = PutioTheme.Typography.caption
    #endif
  #endif
}

enum PutioFormLayout {
  #if os(tvOS)
    static let titleFont = PutioFontRole(
      fontName: PutioTheme.Components.Button.label.fontName,
      size: valueFont.size,
      lineHeight: valueFont.lineHeight,
      textStyle: valueFont.textStyle
    )
    static let valueFont = PutioTheme.TV.Typography.body
    static let labelFont = PutioTheme.TV.Typography.caption
  #else
    static let titleFont = PutioTheme.Typography.body
    static let valueFont = PutioTheme.Typography.body
    static let labelFont = PutioTheme.Typography.caption
  #endif
}
