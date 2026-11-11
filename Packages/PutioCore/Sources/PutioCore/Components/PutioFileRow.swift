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
  public let dateText: String?
  public let secondaryText: String?
  public let isOnDevice: Bool
  public let isWatched: Bool
  public let showsDisclosure: Bool
  public let downloadState: PutioDownloadState

  public init(
    name: String,
    kind: Kind,
    sizeText: String? = nil,
    dateText: String? = nil,
    secondaryText: String? = nil,
    isOnDevice: Bool = false,
    isWatched: Bool = false,
    showsDisclosure: Bool = true,
    downloadState: PutioDownloadState = .idle
  ) {
    self.name = name
    self.kind = kind
    self.sizeText = sizeText
    self.dateText = dateText
    self.secondaryText = secondaryText
    self.isOnDevice = isOnDevice
    self.isWatched = isWatched
    self.showsDisclosure = showsDisclosure
    self.downloadState = downloadState
  }

  public static func sizeText(bytes: Int64, locale: Locale = .current) -> String {
    guard bytes > 0 else { return "0 B" }
    return bytes.formatted(ByteCountFormatStyle(style: .file, locale: locale))
  }

  var icon: PutioIcon {
    #if os(tvOS)
      switch kind {
      case .folder: .folderFill
      case .video: .fileVideo
      case .audio: .fileAudio
      case .image: .image
      case .file: .file
      }
    #else
      switch kind {
      case .folder: .folderFill
      case .video: .fileVideoFill
      case .audio: .fileAudioFill
      case .image: .imageFill
      case .file: .fileFill
      }
    #endif
  }

  #if os(tvOS)
    var detailText: String? {
      let parts = [sizeText, dateText].compactMap { $0 }
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
  #endif
}

public struct PutioFileRow: View {
  private let model: PutioFileRowModel
  private let presentation: PutioDownloadPresentation
  private let onDownloadAction: (PutioDownloadAction) -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @PutioScaledMetric private var iconSize: CGFloat
  @PutioScaledMetric private var contentGap: CGFloat
  @PutioScaledMetric private var textGap: CGFloat
  #if os(tvOS)
    @PutioScaledMetric private var indicatorSize: CGFloat
  #else
    @PutioScaledMetric private var markerSize: CGFloat
    @PutioScaledMetric private var separatorGap: CGFloat
  #endif

  public init(
    _ model: PutioFileRowModel,
    onDownloadAction: @escaping (PutioDownloadAction) -> Void = { _ in }
  ) {
    self.model = model
    presentation = PutioDownloadPresentation(model.downloadState)
    self.onDownloadAction = onDownloadAction
    _iconSize = PutioScaledMetric(PutioFileRowLayout.iconSize)
    _contentGap = PutioScaledMetric(PutioTheme.ScaledMetrics.contentGap)
    _textGap = PutioScaledMetric(PutioTheme.ScaledMetrics.compactContentGap)
    #if os(tvOS)
      _indicatorSize = PutioScaledMetric(PutioFileRowLayout.indicatorSize)
    #else
      _markerSize = PutioScaledMetric(PutioFileRowLayout.markerSize)
      _separatorGap = PutioScaledMetric(PutioFileRowLayout.separatorGap)
    #endif
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
      content
        .opacity(presentation.dimsRow ? PutioFileRowLayout.dimmedOpacity : 1)
    #endif
  }

  private var wrapsDetails: Bool {
    dynamicTypeSize > .large
  }

  private func detail(_ text: String) -> some View {
    Text(text)
      .putioFont(PutioFileRowLayout.detailFont)
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .lineLimit(wrapsDetails ? nil : 1)
      .fixedSize(horizontal: false, vertical: true)
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
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
          .truncationMode(.middle)
          .fixedSize(horizontal: false, vertical: true)
        #if os(tvOS)
          if let detailText = model.detailText {
            detail(detailText)
          }
        #else
          secondLine
        #endif
        if let secondaryText = model.secondaryText {
          detail(secondaryText)
        }
      }
      .frame(
        maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
      if !dynamicTypeSize.isAccessibilitySize {
        Spacer(minLength: contentGap)
      }
      #if os(tvOS)
        if model.isWatched {
          Image(putioIcon: .eye)
            .resizable()
            .scaledToFit()
            .frame(width: indicatorSize, height: indicatorSize)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
            .accessibilityLabel(Text("Watched", bundle: .module))
        }
        if model.kind == .folder, model.showsDisclosure {
          Image(putioIcon: .caretRight)
            .resizable()
            .scaledToFit()
            .frame(width: indicatorSize, height: indicatorSize)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
        }
      #else
        PutioDownloadStateButton(
          presentation: presentation, fileName: model.name, onAction: onDownloadAction)
      #endif
    }
  }

  #if !os(tvOS)
    @ViewBuilder private var secondLine: some View {
      if !presentation.statusLine.isEmpty {
        HStack(alignment: .firstTextBaseline, spacing: separatorGap) {
          ForEach(Array(presentation.statusLine.enumerated()), id: \.offset) { index, segment in
            if index > 0 {
              separator(statusColor)
            }
            segmentText(segment.text, isNumeric: segment.isNumeric, color: statusColor)
          }
        }
      } else if model.sizeText != nil || model.dateText != nil || model.isOnDevice
        || model.isWatched
      {
        HStack(alignment: .firstTextBaseline, spacing: separatorGap) {
          if let sizeText = model.sizeText {
            segmentText(sizeText, isNumeric: true, color: PutioTheme.Colors.textSecondary)
          }
          if model.sizeText != nil, model.dateText != nil {
            separator(PutioTheme.Colors.textSecondary)
          }
          if let dateText = model.dateText {
            segmentText(dateText, isNumeric: false, color: PutioTheme.Colors.textSecondary)
          }
          if model.isOnDevice {
            marker(.arrowCircleDownFill)
              .accessibilityLabel(Text("On this iPhone", bundle: .module))
          }
          if model.isWatched {
            marker(.eye)
              .accessibilityLabel(Text("Watched", bundle: .module))
          }
        }
      }
    }

    private var statusColor: Color {
      switch presentation.tone {
      case .secondary: PutioTheme.Colors.textSecondary
      case .destructive: PutioTheme.Colors.destructive
      }
    }

    @ViewBuilder
    private func segmentText(_ text: String, isNumeric: Bool, color: Color) -> some View {
      if isNumeric {
        Text(text)
          .putioFont(PutioFileRowLayout.detailFont)
          .foregroundStyle(color)
          .lineLimit(wrapsDetails ? nil : 1)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(text)
          .putioFont(PutioFileRowLayout.captionFont)
          .foregroundStyle(color)
          .lineLimit(wrapsDetails ? nil : 1)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    private func separator(_ color: Color) -> some View {
      Text(verbatim: "·")
        .putioFont(PutioFileRowLayout.captionFont)
        .foregroundStyle(color)
        .accessibilityHidden(true)
    }

    private func marker(_ icon: PutioIcon) -> some View {
      Image(putioIcon: icon)
        .resizable()
        .scaledToFit()
        .frame(width: markerSize, height: markerSize)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .alignmentGuide(.firstTextBaseline) { dimensions in
          dimensions.height * PutioFileRowLayout.markerBaselineRatio
        }
    }
  #endif
}

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
    static let captionFont = PutioTheme.Typography.caption
    #if os(iOS) || os(watchOS)
      static let detailFont = PutioTheme.Typography.numeric
    #else
      static let detailFont = PutioTheme.Typography.caption
    #endif
    static let iconSize = PutioMetricRole(value: PutioTheme.Typography.sizeLg, relativeTo: .body)
    static let markerSize = PutioMetricRole(
      value: PutioTheme.Typography.sizeSm, relativeTo: .caption)
    static let separatorGap = PutioMetricRole(value: 6, relativeTo: .caption)
    static let dimmedOpacity = 0.4
    static let markerBaselineRatio = 0.85
  #endif
}
