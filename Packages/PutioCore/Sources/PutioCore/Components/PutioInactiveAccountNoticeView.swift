#if os(iOS)
  import SwiftUI

  public struct PutioInactiveAccountNoticeView: View {
    private let notice: PutioInactiveAccountNotice
    private let now: Date
    @PutioScaledMetric private var iconSize: CGFloat

    public init(notice: PutioInactiveAccountNotice, now: Date = .now) {
      self.notice = notice
      self.now = now
      _iconSize = PutioScaledMetric(PutioInactiveAccountNoticeLayout.iconSize)
    }

    public var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: PutioTheme.Spacing.space2) {
        Image(putioIcon: .warningCircleFill)
          .resizable()
          .scaledToFit()
          .frame(width: iconSize, height: iconSize)
          .foregroundStyle(PutioTheme.Colors.destructive)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
          Text(notice.title)
            .putioFont(PutioInactiveAccountNoticeLayout.titleFont)
            .foregroundStyle(PutioTheme.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
          if let days = notice.daysUntilFilesDeleted(now: now) {
            Text(Self.message(days: days))
              .putioFont(PutioTheme.Typography.body)
              .foregroundStyle(PutioTheme.Colors.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
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
      .accessibilityIdentifier("account.inactive-notice")
    }

    static func message(days: Int) -> AttributedString {
      var message = AttributedString(PutioInactiveAccountNotice.filesDeletionMessage(days: days))
      if let count = message.range(of: String(days)) {
        message[count].font = PutioInactiveAccountNoticeLayout.countFont
      }
      return message
    }
  }

  enum PutioInactiveAccountNoticeLayout {
    static let iconSize = PutioMetricRole(value: PutioTheme.Typography.sizeBase, relativeTo: .body)
    static let titleFont = PutioFontRole(
      fontName: PutioTheme.Typography.heading.fontName,
      size: PutioTheme.Typography.body.size,
      lineHeight: PutioTheme.Typography.body.lineHeight,
      textStyle: .body
    )
    static let countFont = Font.custom(
      PutioTheme.Typography.mono.fontName, size: PutioTheme.Typography.body.size, relativeTo: .body)
  }
#endif
