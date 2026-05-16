import SwiftUI

/// Shared TV list row anatomy. Ports `apps/tv-native/src/components/list-item.tsx`:
/// yellow lucide icon (label.fontSize, 48), title in body type, optional
/// description in caption type with `text-secondary` tint, trailing accessory.
///
/// Trailing accessory rules (matches tv-native):
/// - `trailing` text wins when set (e.g. "Change", "On", "Off").
/// - `watched` true shows the eye glyph (`text-secondary`).
/// - Otherwise the row shows the chevron-right link accessory.
struct PutListRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var watched: Bool = false

    var body: some View {
        HStack(spacing: PutSpacing.md) {
            LucideIcon(name: icon, size: 48)
                .foregroundStyle(Color.put.yellowSolid)

            VStack(alignment: .leading, spacing: PutSpacing.xxs) {
                Text(title)
                    .font(.put.body)
                    .foregroundStyle(Color.put.text)
                    .lineLimit(1)
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
                    .foregroundStyle(Color.put.textSecondary)
            }

            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.put.caption)
                    .foregroundStyle(Color.put.textSecondary)
                    .lineLimit(1)
            } else if !watched {
                LucideIcon(name: "chevron-right", size: 36)
                    .foregroundStyle(Color.put.textSecondary)
            }
        }
        .frame(minHeight: 88)
    }
}
