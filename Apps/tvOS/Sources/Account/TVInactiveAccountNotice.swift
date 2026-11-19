import PutioCore
import SwiftUI

struct TVInactiveAccountNotice: View {
  let notice: PutioInactiveAccountNotice
  var identifier = "account.inactive-notice"
  var now: Date = .now

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: PutioTheme.TV.Spacing.small) {
      Image(putioIcon: .warningCircleFill)
        .resizable()
        .scaledToFit()
        .frame(width: TVInactiveAccountNoticeLayout.iconSize)
        .foregroundStyle(PutioTheme.Colors.destructive)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xxs) {
        Text(notice.title)
          .putioFont(TVInactiveAccountNoticeLayout.titleFont)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        if let days = notice.daysUntilFilesDeleted(now: now) {
          Text(PutioInactiveAccountNotice.filesDeletionMessage(days: days))
            .putioFont(PutioTheme.TV.Typography.caption)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, PutioTheme.TV.Spacing.medium)
    .padding(.vertical, PutioTheme.TV.Spacing.small)
    .background(
      PutioTheme.Colors.surface,
      in: RoundedRectangle(cornerRadius: PutioTheme.TV.radius, style: .continuous)
    )
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier)
  }
}

enum TVInactiveAccountNoticeLayout {
  static let iconSize = PutioTheme.TV.Typography.body.size
  static let titleFont = PutioFontRole(
    fontName: PutioTheme.TV.Typography.label.fontName,
    size: PutioTheme.TV.Typography.body.size,
    lineHeight: PutioTheme.TV.Typography.body.lineHeight,
    textStyle: .body
  )
}

struct TVPlaybackAccountNotice: View {
  let notice: PutioInactiveAccountNotice

  var body: some View {
    PutioErrorStateView(
      title: notice.title,
      message: notice.daysUntilFilesDeleted().map(PutioInactiveAccountNotice.filesDeletionMessage)
    )
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("video.account-notice")
  }
}
