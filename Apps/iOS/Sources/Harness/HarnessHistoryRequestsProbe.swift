import SwiftUI

#if DEBUG
  struct HarnessHistoryRequestsProbe: View {
    var body: some View {
      TimelineView(.periodic(from: .now, by: 0.25)) { _ in
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("History requests")
          .accessibilityValue(String(HarnessSeededAPI.historyListRequestCount()))
          .accessibilityIdentifier("history.requests")
          .allowsHitTesting(false)
      }
    }
  }
#endif
