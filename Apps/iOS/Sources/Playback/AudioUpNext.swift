import PutioCore
import SwiftUI

extension PutioAudioNeighbours {
  static func stored(_ files: [PutioFileItem], around track: PutioAudioTrack)
    -> PutioAudioNeighbours?
  {
    var queue =
      files
      .filter { $0.kind == .audio && $0.parentID == track.parentID }
      .map { PutioQueuedAudio(id: $0.id, parentID: $0.parentID, name: $0.name) }
    guard !queue.isEmpty else { return nil }
    if !queue.contains(where: { $0.id == track.id }) {
      queue.append(PutioQueuedAudio(id: track.id, parentID: track.parentID, name: track.title))
      queue.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
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
          PutioAudioUpNextRow(item: item)
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground(isCurrent: isCurrent))
        .listRowSeparator(item.id == model.queue.last?.id ? .hidden : .automatic, edges: .bottom)
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

private struct PutioAudioUpNextRow: View {
  let item: PutioQueuedAudio
  @PutioScaledMetric(PutioTheme.ScaledMetrics.contentGap) private var contentGap
  @PutioScaledMetric(PutioTheme.ScaledMetrics.compactContentGap) private var textGap

  var body: some View {
    HStack(spacing: contentGap) {
      PutioIconView(
        .fileAudioFill,
        size: PutioMetricRole(value: PutioTheme.Typography.sizeLg, relativeTo: .body)
      )
      .foregroundStyle(PutioTheme.Components.FileRow.icon)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: textGap) {
        Text(item.name)
          .putioFont(PutioTheme.Typography.body)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
        if let duration = item.durationSeconds {
          Text(PutioAudioClock.text(duration))
            .putioFont(PutioTheme.Typography.numeric)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}
