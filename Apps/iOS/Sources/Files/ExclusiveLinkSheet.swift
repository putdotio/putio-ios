import PutioCore
import SwiftUI
import UIKit

extension EnvironmentValues {
  @Entry var putioExclusiveLink: PutioPublicLinkCreate? = nil
}

extension View {
  func putioExclusiveLinkSheet(_ item: Binding<PutioFileItem?>) -> some View {
    modifier(PutioExclusiveLinkHost(item: item))
  }
}

private struct PutioExclusiveLinkHost: ViewModifier {
  @Binding var item: PutioFileItem?
  @Environment(\.putioExclusiveLink) private var create

  func body(content: Content) -> some View {
    content.sheet(item: $item) { item in
      if let create {
        PutioExclusiveLinkSheet(model: PutioExclusiveLinkModel(item: item, create: create))
      }
    }
  }
}

struct PutioExclusiveLinkSheet: View {
  @State private var model: PutioExclusiveLinkModel
  @State private var request = 0
  @State private var contentHeight: CGFloat = 0
  @State private var toast: PutioToast?

  init(model: PutioExclusiveLinkModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    ScrollView {
      content
        .padding(.horizontal, PutioTheme.Spacing.space3)
        .padding(.top, PutioTheme.Spacing.space4)
        .padding(.bottom, PutioTheme.Spacing.space3)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          contentHeight = $0
        }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(idealHeight: contentHeight > 0 ? contentHeight : nil)
    .background(PutioTheme.Components.Sheet.background)
    .presentationDetents(contentHeight > 0 ? [.height(contentHeight)] : [.medium])
    .presentationDragIndicator(.visible)
    .presentationSizing(.form.fitted(horizontal: false, vertical: true))
    .presentationBackground(PutioTheme.Components.Sheet.background)
    .putioToast($toast)
    .task(id: request) {
      guard request > 0 else { return }
      await model.create()
    }
    .accessibilityIdentifier("files.exclusive-link")
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: PutioTheme.Spacing.space3) {
      Text("Exclusive access")
        .putioFont(PutioTheme.Typography.subheading)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(.isHeader)
      Text(bodyText)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(PutioExclusiveLinkCopy.body(name: model.item.name))
        .accessibilityIdentifier("files.exclusive-link.body")
      switch model.state {
      case .created(let url):
        created(url)
      case .refused(let refusal):
        failure(refusal.message)
        createButton(String(localized: "Create link"))
      case .failed(let message):
        failure(message)
        createButton(String(localized: "Try again"))
      case .ready:
        createButton(String(localized: "Create link"))
      case .creating:
        creatingButton
      }
    }
  }

  private var bodyText: AttributedString {
    let marker = "\u{FFFC}"
    let parts = PutioExclusiveLinkCopy.body(name: marker).components(separatedBy: marker)
    var name = AttributedString(PutioExclusiveLinkCopy.displayName(model.item.name))
    name.foregroundColor = PutioTheme.Colors.textPrimary
    name.font = ExclusiveLinkLayout.nameFont
    guard parts.count == 2 else { return AttributedString(parts.joined()) + name }
    return AttributedString(parts[0]) + name + AttributedString(parts[1])
  }

  private func created(_ url: URL) -> some View {
    VStack(alignment: .leading, spacing: PutioTheme.Spacing.space3) {
      Text("Link created. Copy or share it below.")
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .accessibilityIdentifier("files.exclusive-link.created")
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
        Text(PutioExclusiveLinkCopy.address(url))
          .putioFont(ExclusiveLinkLayout.addressFont)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .accessibilityIdentifier("files.exclusive-link.address")
        Text("Expires within 72 hours")
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, PutioTheme.Spacing.space3)
      .padding(.vertical, ExclusiveLinkLayout.addressVerticalPadding)
      .background(
        PutioTheme.Colors.surfaceActive,
        in: RoundedRectangle(cornerRadius: ExclusiveLinkLayout.cornerRadius, style: .continuous)
      )
      HStack(spacing: PutioTheme.Spacing.space2) {
        Button {
          UIPasteboard.general.string = url.absoluteString
          toast = PutioToast(String(localized: "Link copied"))
        } label: {
          label(String(localized: "Copy link"), icon: .copy)
            .foregroundStyle(PutioTheme.Components.Button.primaryForeground)
        }
        .buttonStyle(.borderedProminent)
        .tint(PutioTheme.Colors.accent)
        .accessibilityIdentifier("files.exclusive-link.copy")
        ShareLink(item: url, preview: SharePreview(model.item.name)) {
          label(String(localized: "Share"), icon: .export)
            .foregroundStyle(PutioTheme.Colors.textPrimary)
        }
        .buttonStyle(.borderedProminent)
        .tint(PutioTheme.Colors.surfaceActive)
        .accessibilityIdentifier("files.exclusive-link.share")
      }
      .buttonBorderShape(.capsule)
      .controlSize(.large)
    }
  }

  private func failure(_ message: String) -> some View {
    HStack(alignment: .top, spacing: PutioTheme.Spacing.space2) {
      PutioIconView(.warningCircleFill, size: ExclusiveLinkLayout.failureIconSize)
        .padding(.top, ExclusiveLinkLayout.failureIconInset)
        .accessibilityHidden(true)
      Text(message)
        .putioFont(PutioTheme.Typography.caption)
    }
    .foregroundStyle(PutioTheme.Colors.destructive)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("files.exclusive-link.failure")
  }

  private func createButton(_ title: String) -> some View {
    Button {
      if model.start() { request += 1 }
    } label: {
      label(title, icon: .link)
        .foregroundStyle(PutioTheme.Components.Button.primaryForeground)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
    .controlSize(.large)
    .tint(PutioTheme.Colors.accent)
    .accessibilityIdentifier("files.exclusive-link.create")
  }

  private var creatingButton: some View {
    Button {
    } label: {
      HStack(spacing: PutioTheme.Spacing.space2) {
        ProgressView()
          .tint(PutioTheme.Colors.textSecondary)
        Text("Creating link…")
      }
      .putioFont(ExclusiveLinkLayout.buttonFont)
      .foregroundStyle(PutioTheme.Colors.textPrimary)
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
    .controlSize(.large)
    .tint(PutioTheme.Colors.surfaceActive)
    .allowsHitTesting(false)
    .accessibilityIdentifier("files.exclusive-link.creating")
  }

  private func label(_ title: String, icon: PutioIcon) -> some View {
    HStack(spacing: PutioTheme.Spacing.space2) {
      PutioIconView(icon, size: ExclusiveLinkLayout.buttonIconSize)
        .accessibilityHidden(true)
      Text(title)
    }
    .putioFont(ExclusiveLinkLayout.buttonFont)
    .frame(maxWidth: .infinity)
  }
}

private enum ExclusiveLinkLayout {
  static let cornerRadius: CGFloat = 16
  static let addressVerticalPadding: CGFloat = 12
  static let failureIconInset: CGFloat = 3
  static let buttonIconSize = PutioMetricRole(
    value: PutioTheme.Typography.sizeMd, relativeTo: .body)
  static let failureIconSize = PutioMetricRole(
    value: PutioTheme.Typography.sizeSm, relativeTo: .caption)
  static let nameFont = Font.custom(
    PutioTheme.Typography.subheading.fontName, size: PutioTheme.Typography.body.size,
    relativeTo: .body)
  static let buttonFont = PutioFontRole(
    fontName: PutioTheme.Components.Button.label.fontName,
    size: PutioTheme.Typography.sizeBase,
    lineHeight: PutioTheme.Components.Button.label.lineHeight,
    textStyle: .body)
  static let addressFont = PutioFontRole(
    fontName: PutioTheme.Typography.mono.fontName,
    size: PutioTheme.Typography.body.size,
    lineHeight: PutioTheme.Typography.mono.lineHeight,
    textStyle: .body)
}
