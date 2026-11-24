import PutioCore
import SwiftUI

struct TVHomeScreen: View {
  var notice: PutioInactiveAccountNotice?

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      if let notice {
        TVInactiveAccountNotice(notice: notice)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
  }
}
