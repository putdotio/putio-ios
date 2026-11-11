#if os(iOS)
  import SwiftUI

  public struct PutioStorageMeter: View {
    private let storage: PutioAccountSnapshot.Storage
    @Environment(\.locale) private var locale

    public init(storage: PutioAccountSnapshot.Storage) {
      self.storage = storage
    }

    public var body: some View {
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
        ProgressView(value: storage.usedFraction)
          .tint(PutioTheme.Colors.accent)
          .accessibilityHidden(true)
        Text(storage.meterSummary(locale: locale))
          .putioFont(PutioTheme.Typography.numeric)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
      .padding(.horizontal, PutioTheme.Spacing.space1)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("shell.storage")
    }
  }

  extension PutioAccountSnapshot.Storage {
    func meterSummary(locale: Locale) -> String {
      let used = PutioFileRowModel.sizeText(bytes: usedBytes, locale: locale)
      let total = PutioFileRowModel.sizeText(bytes: totalBytes, locale: locale)
      return String(localized: "\(used) of \(total)", bundle: .module)
    }
  }
#endif
