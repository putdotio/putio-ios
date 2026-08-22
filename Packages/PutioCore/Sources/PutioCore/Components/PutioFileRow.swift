import Foundation
import SwiftUI

public struct PutioFileRowModel: Equatable, Sendable {
  public enum Kind: CaseIterable, Sendable {
    case folder
    case video
    case audio
    case image
    case file
  }

  public let name: String
  public let kind: Kind
  public let sizeText: String?
  public let isWatched: Bool

  public init(name: String, kind: Kind, sizeText: String? = nil, isWatched: Bool = false) {
    self.name = name
    self.kind = kind
    self.sizeText = sizeText
    self.isWatched = isWatched
  }

  public static func sizeText(bytes: Int64, locale: Locale = .current) -> String {
    bytes.formatted(ByteCountFormatStyle(style: .file, locale: locale))
  }

  var icon: PutioIcon {
    switch kind {
    case .folder: .folderFill
    case .video: .fileVideo
    case .audio: .fileAudio
    case .image: .image
    case .file: .file
    }
  }
}

public struct PutioFileRow: View {
  private let model: PutioFileRowModel

  public init(_ model: PutioFileRowModel) {
    self.model = model
  }

  public var body: some View {
    HStack(spacing: PutioFileRowLayout.horizontalPadding) {
      PutioIconView(model.icon, size: PutioFileRowLayout.iconSize)
        .foregroundStyle(PutioTheme.Components.FileRow.icon)
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
        Text(model.name)
          .putioFont(PutioFileRowLayout.nameFont)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
        if let sizeText = model.sizeText {
          Text(sizeText)
            .putioFont(PutioFileRowLayout.detailFont)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: PutioTheme.Spacing.space2)
      if model.isWatched {
        PutioIconView(.eye, size: PutioFileRowLayout.indicatorSize)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityLabel(Text("Watched"))
      }
      if model.kind == .folder {
        PutioIconView(.caretRight, size: PutioFileRowLayout.indicatorSize)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
    }
    .padding(.vertical, PutioTheme.Spacing.space2)
    .padding(.horizontal, PutioFileRowLayout.horizontalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PutioTheme.Components.FileRow.background)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(PutioTheme.Components.FileRow.border)
        .frame(height: PutioTheme.Border.width)
    }
  }
}

// Rows are the core list component; hover/focus states must be obvious
// without inflating row height, so the pressed and focused fills are the
// same solid active step.
public struct PutioListRowButtonStyle: ButtonStyle {
  #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
  #endif

  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(fill(isPressed: configuration.isPressed), in: shape)
      .animation(
        PutioTheme.Motion.easingOut.animation(duration: PutioTheme.Motion.durationFast),
        value: configuration.isPressed
      )
  }

  private var shape: RoundedRectangle {
    #if os(tvOS)
      RoundedRectangle(cornerRadius: PutioTheme.TV.radius)
    #else
      RoundedRectangle(cornerRadius: PutioTheme.Radius.standard)
    #endif
  }

  private func fill(isPressed: Bool) -> Color {
    #if os(tvOS)
      if isFocused { return PutioTheme.Colors.surfaceActive }
    #endif
    return isPressed
      ? PutioTheme.Components.FileRow.backgroundActive
      : PutioTheme.Components.FileRow.background
  }
}

enum PutioFileRowLayout {
  #if os(tvOS)
    static let nameFont = PutioTheme.TV.Typography.body
    static let detailFont = PutioTheme.TV.Typography.numeric
    static let iconSize = PutioMetricRole(value: PutioTheme.TV.Spacing.medium, relativeTo: .body)
    static let indicatorSize = PutioMetricRole(
      value: PutioTheme.TV.Spacing.small,
      relativeTo: .body
    )
    static let horizontalPadding = PutioTheme.TV.Spacing.small
  #else
    static let nameFont = PutioTheme.Typography.body
    #if os(iOS) || os(watchOS)
      static let detailFont = PutioTheme.Typography.numeric
    #else
      static let detailFont = PutioTheme.Typography.caption
    #endif
    static let iconSize = PutioMetricRole(value: PutioTheme.Typography.sizeLg, relativeTo: .body)
    static let indicatorSize = PutioMetricRole(
      value: PutioTheme.Typography.sizeBase,
      relativeTo: .body
    )
    static let horizontalPadding = PutioTheme.Spacing.space3
  #endif
}
