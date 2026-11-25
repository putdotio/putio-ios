import PutioCore
import SwiftUI

/// Home: Continue watching and Pinned as focusable cards, each with a long
/// press menu, or the add-files empty state when both are empty.
struct TVHomeScreen: View {
  let runtime: PutioRuntime
  let account: PutioAccountSnapshot
  let continueWatching: PutioContinueWatchingModel
  let open: (PutioFileItem) -> Void
  let play: (PutioContinueWatchingEntry) -> Void

  @Environment(\.tvHomeActivations) private var activations
  @State private var pins: PutioPinnedFilesModel
  @State private var toast: PutioToast?
  @State private var entryFocusTarget: PutioFileID?
  @FocusState private var focusedEntry: PutioFileID?

  init(
    runtime: PutioRuntime, account: PutioAccountSnapshot,
    continueWatching: PutioContinueWatchingModel,
    open: @escaping (PutioFileItem) -> Void,
    play: @escaping (PutioContinueWatchingEntry) -> Void
  ) {
    self.runtime = runtime
    self.account = account
    self.continueWatching = continueWatching
    self.open = open
    self.play = play
    _pins = State(
      initialValue: PutioPinnedFilesModel(
        actions: PutioPinnedFilesActions(runtime: runtime), rootName: TVFolderCopy.yourFiles))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.medium) {
      if let notice = PutioInactiveAccountNotice(account: account) {
        TVInactiveAccountNotice(notice: notice)
      }
      if showsEmptyState {
        TVHomeEmptyState()
      } else {
        VStack(alignment: .leading, spacing: TVHomeLayout.sectionGap) {
          if !continueWatching.entries.isEmpty {
            continueWatchingSection
          }
          pinnedSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .tvOverscanPadding()
    .background(PutioTheme.Colors.background.ignoresSafeArea())
    .putioToast($toast)
    .task(id: activations) {
      await pins.load()
      await continueWatching.reconcile(loadFile: { try await runtime.getFile(fileID: $0) })
    }
    .task(id: entryFocusTarget) {
      guard let target = entryFocusTarget else { return }
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      entryFocusTarget = nil
      focusedEntry = target
    }
    .onChange(of: pins.editFailure) { _, failure in
      guard failure != nil else { return }
      toast = PutioToast(PutioScreenErrorKind.failed.message, icon: .warning, width: .fit)
      pins.clearEditFailure()
    }
  }

  private var showsEmptyState: Bool {
    guard continueWatching.entries.isEmpty else { return false }
    switch pins.state {
    case .loading: return false
    case .unavailable: return true
    case .loaded(let items): return items.isEmpty
    }
  }

  private var continueWatchingSection: some View {
    VStack(alignment: .leading, spacing: TVHomeLayout.labelGap) {
      sectionLabel(PutioHomeCopy.continueWatching)
      cardRow {
        ForEach(continueWatching.entries) { entry in
          Button {
            play(entry)
          } label: {
            TVContinueWatchingCard(entry: entry)
          }
          .contextMenu {
            Button {
              remove(entry)
            } label: {
              Label {
                Text(PutioHomeCopy.removeFromContinueWatching)
              } icon: {
                Image(putioIcon: .x)
              }
            }
            .accessibilityIdentifier("home.continue-watching.remove")
          }
          .focused($focusedEntry, equals: entry.fileID)
          .accessibilityLabel(Text(PutioHomeCopy.resume(entry)))
          .accessibilityIdentifier("home.continue-watching.item.\(entry.fileID.rawValue)")
        }
      }
    }
  }

  @ViewBuilder
  private var pinnedSection: some View {
    switch pins.state {
    case .loading, .unavailable:
      EmptyView()
    case .loaded(let items):
      VStack(alignment: .leading, spacing: TVHomeLayout.labelGap) {
        sectionLabel(PutioHomeCopy.pinned)
        if items.isEmpty {
          TVNothingPinned()
        } else {
          cardRow {
            ForEach(items) { pinned in
              Button {
                open(pinned.item)
              } label: {
                TVPinnedCard(item: pinned.item, runtime: runtime)
              }
              .contextMenu {
                ForEach([PutioFileMenuRow.open, .unpin], id: \.self) { row in
                  Button {
                    perform(row, on: pinned.item)
                  } label: {
                    Label {
                      Text(
                        row.title(
                          for: pinned.item, style: .panel, trashEnabled: account.trashEnabled)
                          ?? "")
                    } icon: {
                      Image(putioIcon: row.icon)
                    }
                  }
                  .accessibilityIdentifier("home.pinned.\(row.rawValue)")
                }
              }
              .accessibilityIdentifier("home.pinned.item.\(pinned.item.id.rawValue)")
            }
          }
        }
      }
    }
  }

  private func sectionLabel(_ title: String) -> some View {
    Text(title)
      .putioFont(PutioTVTypeScale.label)
      .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      .accessibilityAddTraits(.isHeader)
  }

  private func cardRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: TVHomeLayout.cardGap) {
        content()
      }
      .buttonStyle(TVHomeCardButtonStyle())
    }
    .scrollClipDisabled()
    .focusSection()
  }

  private func remove(_ entry: PutioContinueWatchingEntry) {
    let ids = continueWatching.entries.map(\.fileID)
    if let index = ids.firstIndex(of: entry.fileID) {
      entryFocusTarget =
        ids.indices.contains(index + 1) ? ids[index + 1] : index > 0 ? ids[index - 1] : nil
    }
    continueWatching.remove(entry.fileID)
  }

  private func perform(_ row: PutioFileMenuRow, on item: PutioFileItem) {
    switch row {
    case .unpin: Task { await pins.unpin(item) }
    default: open(item)
    }
  }
}

private struct TVContinueWatchingCard: View {
  let entry: PutioContinueWatchingEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      TVHomeCardTitle(icon: .fileVideoFill, name: entry.name)
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: TVHomeLayout.metaGap) {
        TVHomeProgressLine(fraction: entry.fraction)
        Text(PutioHomeCopy.timeLeft(entry))
          .putioFont(PutioTVTypeScale.numeric)
          .foregroundStyle(.putioRowSecondary)
          .lineLimit(1)
      }
    }
  }
}

private struct TVPinnedCard: View {
  let item: PutioFileItem
  let runtime: PutioRuntime

  @Environment(\.locale) private var locale
  @State private var itemCount: Int?

  var body: some View {
    let row = PutioBrowserItemPresentation(item: item, relativeTo: .now, locale: locale).row
    VStack(alignment: .leading, spacing: 0) {
      TVHomeCardTitle(icon: row.kind.icon, name: item.name)
      Spacer(minLength: 0)
      Text(meta(size: row.sizeText))
        .putioFont(PutioTVTypeScale.caption)
        .foregroundStyle(.putioRowSecondary)
        .lineLimit(1)
    }
    .task(id: item.id) {
      guard item.kind == .folder else { return }
      itemCount = try? await runtime.listFiles(parentID: item.id, perPage: 1).itemCount
    }
  }

  private func meta(size: String?) -> String {
    [itemCount.map(PutioHomeCopy.itemCount), size].compactMap { $0 }.joined(separator: " · ")
  }
}

private struct TVHomeCardTitle: View {
  let icon: PutioIcon
  let name: String

  var body: some View {
    VStack(alignment: .leading, spacing: TVHomeLayout.titleGap) {
      Image(putioIcon: icon)
        .resizable()
        .scaledToFit()
        .frame(width: TVHomeLayout.glyphSize, height: TVHomeLayout.glyphSize)
        .foregroundStyle(.putioRowIcon)
        .accessibilityHidden(true)
      Text(name)
        .putioFont(PutioTVTypeScale.rowTitle)
        .foregroundStyle(.putioRowPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }
}

private struct TVHomeProgressLine: View {
  let fraction: Double
  @Environment(\.putioTVRowState) private var state

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(track)
        Capsule()
          .fill(state == .focused ? PutioTVRowFocus.foreground : PutioTheme.Colors.accent)
          .frame(width: proxy.size.width * max(fraction, TVHomeLayout.minimumProgress))
      }
    }
    .frame(height: TVHomeLayout.progressHeight)
    .accessibilityHidden(true)
  }

  private var track: Color {
    state == .focused ? .black.opacity(0.15) : .white.opacity(0.18)
  }
}

private struct TVNothingPinned: View {
  var body: some View {
    HStack(spacing: TVHomeLayout.emptyGap) {
      Text(PutioKaomoji.nothingYet.rawValue)
        .putioFont(PutioTVTypeScale.title)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: TVHomeLayout.metaGap) {
        Text(PutioHomeCopy.nothingPinned)
          .putioFont(PutioTVTypeScale.rowTitle)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        Text(PutioHomeCopy.nothingPinnedHint)
          .putioFont(PutioTVTypeScale.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      }
    }
    .frame(height: TVHomeLayout.emptyHeight)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("home.pinned.empty")
  }
}

private struct TVHomeCardButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    TVHomeCardBody(configuration: configuration)
  }
}

private struct TVHomeCardBody: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.isFocused) private var isFocused

  var body: some View {
    configuration.label
      .environment(\.putioTVRowState, isFocused ? .focused : .resting)
      .padding(.horizontal, TVHomeLayout.cardPaddingX)
      .padding(.vertical, TVHomeLayout.cardPaddingY)
      .frame(
        width: TVHomeLayout.cardWidth, height: TVHomeLayout.cardHeight, alignment: .topLeading
      )
      .background {
        RoundedRectangle(cornerRadius: TVHomeLayout.cardRadius, style: .continuous)
          .fill(isFocused ? PutioTVRowFocus.fill : PutioTheme.Colors.surfaceActive)
      }
      .scaleEffect(isFocused ? TVHomeLayout.focusScale : 1)
      .shadow(
        color: .black.opacity(isFocused ? TVHomeLayout.shadowOpacity : 0),
        radius: TVHomeLayout.shadowRadius, y: TVHomeLayout.shadowOffset
      )
      .opacity(configuration.isPressed ? TVRowLayout.pressedOpacity : 1)
      .animation(.easeOut(duration: TVRowLayout.focusDuration), value: isFocused)
  }
}

enum TVHomeLayout {
  static let cardWidth: CGFloat = 410
  static let cardHeight: CGFloat = 240
  static let cardRadius: CGFloat = 24
  static let cardPaddingX: CGFloat = 26
  static let cardPaddingY: CGFloat = 24
  static let cardGap: CGFloat = 40
  static let sectionGap: CGFloat = 56
  static let labelGap: CGFloat = 20
  static let titleGap: CGFloat = 20
  static let metaGap: CGFloat = 6
  static let glyphSize: CGFloat = 56
  static let progressHeight: CGFloat = 6
  static let minimumProgress = 0.02
  static let focusScale: CGFloat = 1.06
  static let shadowOpacity = 0.55
  static let shadowRadius: CGFloat = 22
  static let shadowOffset: CGFloat = 20
  static let emptyGap: CGFloat = 28
  static let emptyHeight: CGFloat = 156
}

struct TVHomeEmptyState: View {
  static let addFilesURL = "https://app.put.io"

  var body: some View {
    VStack(spacing: PutioTheme.TV.Spacing.medium) {
      PutioEmptyStateView(
        kaomoji: .nothingHere,
        title: String(localized: "Nothing here yet.", bundle: .putioCore),
        message: String(
          localized: "Scan to add files from your phone. What you watch and pin shows up here.",
          bundle: .putioCore)
      )
      .fixedSize(horizontal: false, vertical: true)
      PutioQRCodeView(Self.addFilesURL, size: 240)
        .accessibilityElement()
        .accessibilityLabel(Text("QR code that opens put.io", bundle: .putioCore))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .tvFocusAnchor()
    .accessibilityIdentifier("home.empty")
  }
}

extension EnvironmentValues {
  @Entry var tvHomeActivations = 0
}
