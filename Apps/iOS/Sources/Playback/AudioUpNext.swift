import PutioCore
import SwiftUI

extension PutioAudioNeighbours {
  /// The downloaded audio files of `track`'s folder in name order, for a
  /// folder put.io cannot list right now; `nil` when none is stored.
  static func stored(_ items: [PutioOfflineItem], around track: PutioAudioTrack)
    -> PutioAudioNeighbours?
  {
    let queue =
      items
      .filter { $0.kind == .audio && $0.parentID == track.parentID && $0.isPlayable }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      .map { PutioQueuedAudio(id: $0.id, parentID: $0.parentID, name: $0.name) }
    guard !queue.isEmpty else { return nil }
    return PutioAudioNeighbours(of: track.id, in: queue, folderName: nil)
  }
}

struct PutioAudioUpNextSheet: View {
  let model: PutioAudioPlayerModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    PutioSheetScaffold(
      title: String(localized: "Up next"),
      dismissButton: nil,
      trailingButton: PutioSheetIconButton(icon: .x, label: String(localized: "Close")) {
        dismiss()
      }
    ) {
      PutioAudioUpNextList(model: model)
    }
    .presentationDetents([.medium, .large])
  }
}

struct PutioAudioUpNextList: View {
  let model: PutioAudioPlayerModel

  var body: some View {
    ScrollViewReader { proxy in
      List(model.queue) { item in
        let isCurrent = item.id == model.track.id
        Button {
          model.play(item)
        } label: {
          PutioFileRow(
            PutioFileRowModel(
              name: item.name,
              kind: .audio,
              secondaryText: item.durationSeconds.map(PutioAudioClock.text),
              showsDisclosure: false))
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground(isCurrent: isCurrent))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint(Text("Play"))
        .accessibilityIdentifier("audio.up-next.\(item.id.rawValue)")
        .id(item.id)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .accessibilityIdentifier("audio.up-next.list")
      .onAppear { proxy.scrollTo(model.track.id) }
      .onChange(of: model.track.id) { _, id in
        withAnimation { proxy.scrollTo(id) }
      }
    }
  }

  @ViewBuilder
  private func rowBackground(isCurrent: Bool) -> some View {
    if isCurrent {
      RoundedRectangle(cornerRadius: PutioTheme.Radius.large)
        .fill(PutioTheme.Colors.accent.opacity(0.14))
        .padding(.horizontal, PutioTheme.Spacing.space2)
    } else {
      Color.clear
    }
  }
}
