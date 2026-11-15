import PutioCore
import SwiftUI

struct PutioSubtitleSizeAndTimingPanel: View {
  let transport: PutioVideoTransport
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    PutioSheetScaffold(
      title: String(localized: "Size and timing"),
      dismissButton: nil,
      trailingButton: PutioSheetIconButton(icon: .x, label: String(localized: "Close")) {
        dismiss()
      }
    ) {
      Form {
        Section {
          Picker(String(localized: "Text size"), selection: size) {
            ForEach(PutioSubtitleTextSize.allCases) { size in
              Text(size.title).tag(size)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier("video.subtitle-size")
        } header: {
          Text(String(localized: "Text size"))
            .textCase(nil)
        }
        Section {
          Stepper(
            value: tenths,
            in: -PutioSubtitleTiming.limitTenths...PutioSubtitleTiming.limitTenths
          ) {
            Text(verbatim: transport.subtitleTiming.text)
              .putioFont(PutioTheme.Typography.numeric)
              .foregroundStyle(PutioTheme.Colors.textPrimary)
          }
          .accessibilityLabel(String(localized: "Timing"))
          .accessibilityValue(transport.subtitleTiming.text)
          .accessibilityIdentifier("video.subtitle-timing")
          Button(String(localized: "Reset")) {
            transport.resetSubtitleTiming()
          }
          .frame(maxWidth: .infinity)
          .tint(PutioTheme.Colors.textPrimary)
          .accessibilityIdentifier("video.subtitle-timing.reset")
        } header: {
          Text(String(localized: "Timing"))
            .textCase(nil)
        } footer: {
          Text(String(localized: "Font and colours follow iOS caption settings."))
        }
      }
    }
    .presentationDetents([.medium, .large])
    .frame(idealWidth: Self.popoverWidth, idealHeight: Self.popoverHeight)
    .accessibilityIdentifier("video.size-and-timing")
  }

  private var size: Binding<PutioSubtitleTextSize> {
    Binding(get: { transport.subtitleSize }, set: { transport.setSubtitleSize($0) })
  }

  private var tenths: Binding<Int> {
    Binding(
      get: { transport.subtitleTiming.tenths },
      set: { value in
        if value > transport.subtitleTiming.tenths {
          transport.moveSubtitlesLater()
        } else if value < transport.subtitleTiming.tenths {
          transport.moveSubtitlesEarlier()
        }
      })
  }

  private static let popoverWidth: CGFloat = 420
  private static let popoverHeight: CGFloat = 400
}
