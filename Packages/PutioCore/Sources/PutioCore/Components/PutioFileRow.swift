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

// The central list row. On iOS and watchOS it is plain content for a native
// List: system separators, insets, and row heights per the HIG, with every
// metric scaled so icons and gaps track the user's text size. tvOS keeps the
// contract's painted row with the solid focus fill.
public struct PutioFileRow: View {
  private let model: PutioFileRowModel
  private let showsFolderDisclosure: Bool

  @PutioScaledMetric private var iconSize: CGFloat
  @PutioScaledMetric private var indicatorSize: CGFloat
  @PutioScaledMetric private var contentGap: CGFloat
  @PutioScaledMetric private var textGap: CGFloat

  public init(_ model: PutioFileRowModel, showsFolderDisclosure: Bool = true) {
    self.model = model
    self.showsFolderDisclosure = showsFolderDisclosure
    _iconSize = PutioScaledMetric(PutioFileRowLayout.iconSize)
    _indicatorSize = PutioScaledMetric(PutioFileRowLayout.indicatorSize)
    _contentGap = PutioScaledMetric(PutioTheme.ScaledMetrics.contentGap)
    _textGap = PutioScaledMetric(PutioTheme.ScaledMetrics.compactContentGap)
  }

  public var body: some View {
    #if os(tvOS)
      content
        .padding(.vertical, PutioTheme.TV.Spacing.small)
        .padding(.horizontal, PutioTheme.TV.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
          Rectangle()
            .fill(PutioTheme.Components.FileRow.border)
            .frame(height: PutioTheme.Border.width)
        }
    #else
      // No extra padding: the List's system row insets own the row height
      // (ios-e00: 60pt min, Dynamic Type drives it, never pinned).
      content
    #endif
  }

  private var content: some View {
    HStack(spacing: contentGap) {
      Image(putioIcon: model.icon)
        .resizable()
        .scaledToFit()
        .frame(width: iconSize, height: iconSize)
        .foregroundStyle(PutioTheme.Components.FileRow.icon)
      VStack(alignment: .leading, spacing: textGap) {
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
      Spacer(minLength: contentGap)
      if model.isWatched {
        Image(putioIcon: .eye)
          .resizable()
          .scaledToFit()
          .frame(width: indicatorSize, height: indicatorSize)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityLabel(Text("Watched"))
      }
      if rendersFolderDisclosure {
        Image(putioIcon: .caretRight)
          .resizable()
          .scaledToFit()
          .frame(width: indicatorSize, height: indicatorSize)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
    }
  }

  var rendersFolderDisclosure: Bool {
    model.kind == .folder && showsFolderDisclosure
  }
}

#if os(tvOS)
  // TV rows go transparent to the solid active fill on focus, per the TV
  // contract: a fill, never a lift.
  public struct PutioListRowButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

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
      RoundedRectangle(cornerRadius: PutioTheme.TV.radius)
    }

    private func fill(isPressed: Bool) -> Color {
      if isFocused { return PutioTheme.Colors.surfaceActive }
      return isPressed
        ? PutioTheme.Components.FileRow.backgroundActive
        : PutioTheme.Components.FileRow.background
    }
  }
#endif

enum PutioFileRowLayout {
  #if os(tvOS)
    static let nameFont = PutioTheme.TV.Typography.body
    static let detailFont = PutioTheme.TV.Typography.numeric
    static let iconSize = PutioMetricRole(
      value: PutioTheme.TV.Typography.label.size,
      relativeTo: .body
    )
    static let indicatorSize = PutioMetricRole(
      value: PutioTheme.TV.Typography.caption.size,
      relativeTo: .body
    )
  #else
    static let nameFont = PutioTheme.Typography.body
    #if os(iOS) || os(watchOS)
      static let detailFont = PutioTheme.Typography.numeric
    #else
      static let detailFont = PutioTheme.Typography.caption
    #endif
    // ios-e00: file icons are Phosphor at 24pt, every type.
    static let iconSize = PutioMetricRole(value: PutioTheme.Typography.sizeLg, relativeTo: .body)
    static let indicatorSize = PutioMetricRole(
      value: PutioTheme.Typography.sizeMd,
      relativeTo: .body
    )
  #endif
}
