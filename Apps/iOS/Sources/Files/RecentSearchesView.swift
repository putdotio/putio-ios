import PutioCore
import SwiftUI

struct RecentSearchesView: View {
  let model: PutioRecentSearchesModel
  let onSearch: (String) -> Void

  var body: some View {
    if model.terms.isEmpty {
      PutioEmptyStateView.textOnly(
        title: String(localized: "Find your files"),
        message: String(localized: "Enter a name or keyword to search your put.io account."))
    } else {
      List {
        header
        ForEach(model.terms, id: \.self) { term in
          RecentSearchRow(term: term) {
            onSearch(term)
          } onRemove: {
            Task { await model.remove(term) }
          }
        }
      }
      .listStyle(.plain)
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Recent searches")
        .putioFont(PutioTheme.Typography.caption)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: PutioTheme.Spacing.space2)
      Button("Clear") {
        Task { await model.clear() }
      }
      .putioFont(PutioTheme.Typography.caption)
      .fontWeight(.semibold)
      .foregroundStyle(PutioTheme.Colors.textPrimary)
      .buttonStyle(.plain)
      .accessibilityIdentifier("files.search-recent-clear")
    }
    .listRowInsets(.top, PutioTheme.Spacing.space3)
    .listRowInsets(.bottom, 0)
    .listRowSeparator(.hidden)
    .listRowBackground(PutioTheme.Colors.background)
  }
}

private struct RecentSearchRow: View {
  let term: String
  let onSearch: () -> Void
  let onRemove: () -> Void

  private static let minimumHitSize: CGFloat = 44

  @PutioScaledMetric(PutioTheme.ScaledMetrics.contentGap) private var contentGap

  var body: some View {
    HStack(spacing: contentGap) {
      Button(action: onSearch) {
        HStack(spacing: contentGap) {
          PutioIconView(
            .clockCounterClockwise,
            size: PutioMetricRole(value: PutioTheme.Typography.sizeLg, relativeTo: .body)
          )
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityHidden(true)
          Text(term)
            .putioFont(PutioTheme.Typography.body)
            .foregroundStyle(PutioTheme.Colors.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("files.search-recent.\(term)")
      Button(action: onRemove) {
        PutioIconView(
          .x, size: PutioMetricRole(value: PutioTheme.Typography.sizeMd, relativeTo: .body)
        )
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .frame(minWidth: Self.minimumHitSize, minHeight: Self.minimumHitSize)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(String(localized: "Remove \(term) from recent searches"))
      .accessibilityIdentifier("files.search-recent-remove.\(term)")
    }
    .listRowInsets(.vertical, PutioTheme.Spacing.space1)
    .listRowBackground(PutioTheme.Colors.background)
  }
}
