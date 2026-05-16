import SwiftUI

/// Shared TV list row. Used by Home, Files, Search, History, and Account so
/// list layouts stay consistent across screens. Mirrors the React Native
/// `ListItem` component's anatomy (icon + title + optional subtitle + trailing
/// accessory).
struct PutListRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var trailing: String?
    var watched: Bool = false

    var body: some View {
        HStack(spacing: PutSpacing.md) {
            LucideIcon(name: icon, size: 44)
                .foregroundStyle(Color.put.textPrimary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.put.headline)
                    .foregroundStyle(Color.put.textPrimary)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.put.caption)
                        .foregroundStyle(Color.put.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: PutSpacing.md)
            if watched {
                LucideIcon(name: "eye", size: 32)
                    .foregroundStyle(Color.put.watched)
            }
            if let trailing {
                Text(trailing)
                    .font(.put.secondary)
                    .foregroundStyle(Color.put.textSecondary)
            } else {
                LucideIcon(name: "chevron-right", size: 28)
                    .foregroundStyle(Color.put.textTertiary)
            }
        }
    }
}
