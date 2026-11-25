import PutioCore
import SwiftUI

enum TVDirectChip: Hashable, CaseIterable {
  case subtitles
  case audio
  case speed
  case nextFile
}

enum TVDirectMenu: Hashable {
  case subtitles
  case sizeAndTiming
  case audio
  case speed

  var chip: TVDirectChip {
    switch self {
    case .subtitles, .sizeAndTiming: .subtitles
    case .audio: .audio
    case .speed: .speed
    }
  }

  var width: CGFloat {
    switch self {
    case .subtitles, .audio: TVDirectMenuMetrics.wideMenuWidth
    case .sizeAndTiming, .speed: TVDirectMenuMetrics.menuWidth
    }
  }

  /// Each chip's menu keeps its own distance from the controls' trailing edge.
  var trailingInset: CGFloat {
    let steps: CGFloat =
      switch chip {
      case .subtitles, .nextFile: 2
      case .audio: 1
      case .speed: 0
      }
    return TVDirectMenuMetrics.menuInset + TVDirectMenuMetrics.menuStep * steps
  }
}

enum TVDirectFocus: Hashable {
  case surface
  case chip(TVDirectChip)
  case row(String)

  var identifier: String {
    switch self {
    case .surface: "surface"
    case .chip(let chip): "chip.\(chip.identifier)"
    case .row(let id): id
    }
  }
}

struct TVDirectMenuRow: Identifiable {
  let id: String
  let title: String
  var detail: String?
  var checked = false
  var icon: PutioIcon?
  var startsSection = false
  let action: @MainActor () -> Void
}

/// The chips of boards `rd-tvos-dp-01` to `rd-tvos-dp-10`: Subtitles, Audio,
/// Speed with its value, and Next file when the folder has one.
struct TVDirectChipRow: View {
  let speed: PutioAudioSpeed
  let audioEnabled: Bool
  let showsNextFile: Bool
  let openChip: TVDirectChip?
  var focus: FocusState<TVDirectFocus?>.Binding
  let select: @MainActor (TVDirectChip) -> Void

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.small) {
      chip(
        .subtitles, icon: .closedCaptioning,
        label: String(localized: "Subtitles", bundle: .putioCore))
      chip(.audio, icon: .speakerHigh, label: String(localized: "Audio", bundle: .putioCore))
        .disabled(!audioEnabled)
      chip(
        .speed, icon: .gauge, label: String(localized: "Speed", bundle: .putioCore),
        text: speed.title)
      if showsNextFile {
        chip(
          .nextFile, icon: .skipForwardFill,
          label: String(localized: "Next file", bundle: .putioCore),
          text: String(localized: "Next file", bundle: .putioCore))
      }
    }
    .focusSection()
  }

  private func dims(_ chip: TVDirectChip) -> Bool {
    openChip != nil && openChip != chip
  }

  private func chip(
    _ chip: TVDirectChip, icon: PutioIcon, label: String, text: String? = nil
  ) -> some View {
    Button {
      select(chip)
    } label: {
      HStack(spacing: PutioTheme.TV.Spacing.xs) {
        Image(putioIcon: icon)
          .resizable()
          .scaledToFit()
          .frame(width: TVDirectMenuMetrics.chipIcon, height: TVDirectMenuMetrics.chipIcon)
        if let text {
          Text(text).putioFont(PutioTheme.TV.Typography.caption)
        }
      }
      .padding(.horizontal, TVDirectMenuMetrics.chipPadding)
      .frame(minWidth: TVDirectMenuMetrics.chipHeight, minHeight: TVDirectMenuMetrics.chipHeight)
    }
    .buttonStyle(TVDirectChipStyle(isOpen: openChip == chip, isDimmed: dims(chip)))
    .focused(focus, equals: .chip(chip))
    .accessibilityLabel(label)
    .accessibilityIdentifier("video.chip.\(chip.identifier)")
  }
}

extension TVDirectChip {
  var identifier: String {
    switch self {
    case .subtitles: "subtitles"
    case .audio: "audio"
    case .speed: "speed"
    case .nextFile: "next-file"
    }
  }
}

private struct TVDirectChipStyle: ButtonStyle {
  let isOpen: Bool
  let isDimmed: Bool

  func makeBody(configuration: Configuration) -> some View {
    TVDirectChipBody(configuration: configuration, isOpen: isOpen, isDimmed: isDimmed)
  }
}

private struct TVDirectChipBody: View {
  let configuration: ButtonStyleConfiguration
  let isOpen: Bool
  let isDimmed: Bool
  @Environment(\.isFocused) private var isFocused
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    configuration.label
      .foregroundStyle(isFocused ? Color.black : PutioTheme.TV.Colors.textPrimary)
      .background(Capsule().fill(fill))
      .overlay(Capsule().strokeBorder(.white.opacity(isFocused ? 0 : 0.18)))
      .opacity(isEnabled ? 1 : 0.4)
      .colorMultiply(isDimmed ? TVDirectMenuMetrics.dimmed : .white)
      .scaleEffect(isFocused ? 1.06 : 1)
      .animation(.easeOut(duration: TVRowLayout.focusDuration), value: isFocused)
  }

  private var fill: Color {
    if isFocused { return .white }
    return .white.opacity(isOpen ? 0.3 : 0.14)
  }
}

/// A chip's menu: a titled card of rows over the controls.
struct TVDirectMenuPanel: View {
  let menu: TVDirectMenu
  let rows: [TVDirectMenuRow]
  var focus: FocusState<TVDirectFocus?>.Binding
  var highlighted: String?
  var onMove: (@MainActor (String, MoveCommandDirection) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(menu.title)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .padding(.horizontal, TVDirectMenuMetrics.rowPadding)
        .padding(.top, TVDirectMenuMetrics.headerTop)
        .padding(.bottom, TVDirectMenuMetrics.headerBottom)
        .accessibilityAddTraits(.isHeader)
      if rowsHeight > TVDirectMenuMetrics.rowsMaxHeight {
        ScrollView { rowStack }.frame(height: TVDirectMenuMetrics.rowsMaxHeight)
      } else {
        rowStack
      }
    }
    .padding(TVDirectMenuMetrics.menuPadding)
    .frame(width: menu.width, alignment: .leading)
    .background {
      let shape = RoundedRectangle(
        cornerRadius: TVDirectMenuMetrics.menuRadius, style: .continuous)
      shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
        .overlay(shape.fill(Color(white: 0.27).opacity(0.55)))
        .shadow(color: .black.opacity(0.6), radius: 40, y: 30)
    }
    .overlay(
      RoundedRectangle(cornerRadius: TVDirectMenuMetrics.menuRadius, style: .continuous)
        .strokeBorder(.white.opacity(0.22))
    )
    .padding(.trailing, menu.trailingInset)
    .focusSection()
    .accessibilityElement(children: .contain)
  }

  private var rowsHeight: CGFloat {
    let separators = rows.filter(\.startsSection).count
    return CGFloat(rows.count) * TVDirectMenuMetrics.rowHeight
      + CGFloat(separators) * (1 + TVDirectMenuMetrics.separatorInset)
  }

  private var rowStack: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(rows) { row in
        if row.startsSection {
          Rectangle()
            .fill(.white.opacity(0.12))
            .frame(height: 1)
            .padding(.vertical, TVDirectMenuMetrics.separatorInset / 2)
            .padding(.horizontal, TVDirectMenuMetrics.separatorInset)
        }
        Button(action: row.action) { TVDirectMenuRowLabel(row: row) }
          .buttonStyle(TVRowButtonStyle())
          .environment(\.putioTVRowState, row.id == highlighted ? .focused : .resting)
          .focused(focus, equals: .row(row.id))
          .onMoveCommand { direction in onMove?(row.id, direction) }
          .accessibilityIdentifier(row.id)
      }
    }
  }
}

private struct TVDirectMenuRowLabel: View {
  let row: TVDirectMenuRow

  var body: some View {
    HStack(spacing: TVDirectMenuMetrics.checkGap) {
      TVDirectMenuRowMark(row: row)
      Text(row.title)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(.putioRowPrimary)
        .lineLimit(1)
      Spacer(minLength: PutioTheme.TV.Spacing.small)
      if let detail = row.detail {
        Text(detail)
          .putioFont(PutioTheme.TV.Typography.numeric)
          .foregroundStyle(.putioRowSecondary)
      }
    }
    .padding(.horizontal, TVDirectMenuMetrics.rowPadding)
    .frame(height: TVDirectMenuMetrics.rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(row.checked ? .isSelected : [])
  }
}

private struct TVDirectMenuRowMark: View {
  let row: TVDirectMenuRow
  @Environment(\.putioTVRowState) private var state

  var body: some View {
    ZStack {
      if let icon = row.icon {
        Image(putioIcon: icon).resizable().scaledToFit()
      } else if row.checked {
        Image(putioIcon: .check).resizable().scaledToFit()
      }
    }
    .foregroundStyle(
      state == .focused ? AnyShapeStyle(.putioRowPrimary) : AnyShapeStyle(PutioTheme.Colors.accent)
    )
    .frame(width: TVDirectMenuMetrics.checkSize, height: TVDirectMenuMetrics.checkSize)
    .frame(width: TVDirectMenuMetrics.checkColumn)
  }
}

enum TVDirectBadge: Equatable {
  case paused
  case skippedForward
  case skippedBack

  var identifier: String {
    switch self {
    case .paused: "paused"
    case .skippedForward: "forward"
    case .skippedBack: "back"
    }
  }
}

/// The round badge of boards `rd-tvos-dp-02`, `-03` and `-11`.
struct TVDirectBadgeView: View {
  let badge: TVDirectBadge

  var body: some View {
    ZStack {
      Circle().fill(Color(white: 0.27).opacity(0.55)).background(.ultraThinMaterial, in: Circle())
        .environment(\.colorScheme, .dark)
      symbol
        .foregroundStyle(.white)
    }
    .frame(width: TVDirectMenuMetrics.badgeSize, height: TVDirectMenuMetrics.badgeSize)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    .padding(.horizontal, TVDirectMenuMetrics.badgeInset)
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityIdentifier("video.badge")
  }

  @ViewBuilder private var symbol: some View {
    switch badge {
    case .paused:
      Image(putioIcon: .pauseFill).resizable().scaledToFit()
        .frame(width: TVDirectMenuMetrics.pauseSymbol, height: TVDirectMenuMetrics.pauseSymbol)
    case .skippedForward:
      Image(systemName: "goforward.10").font(.system(size: TVDirectMenuMetrics.skipSymbol))
    case .skippedBack:
      Image(systemName: "gobackward.10").font(.system(size: TVDirectMenuMetrics.skipSymbol))
    }
  }

  private var alignment: Alignment {
    switch badge {
    case .paused: .center
    case .skippedForward: .trailing
    case .skippedBack: .leading
    }
  }

  private static let skipSeconds = Int(PutioVideoTimeline.skipInterval)

  private var label: String {
    switch badge {
    case .paused: String(localized: "Paused", bundle: .putioCore)
    case .skippedForward:
      String(localized: "Forward \(Self.skipSeconds) seconds", bundle: .putioCore)
    case .skippedBack: String(localized: "Back \(Self.skipSeconds) seconds", bundle: .putioCore)
    }
  }
}

enum TVDirectMenuMetrics {
  static let chipHeight: CGFloat = 64
  static let chipIcon: CGFloat = 32
  static let chipPadding: CGFloat = 20
  static let menuWidth: CGFloat = 560
  static let wideMenuWidth: CGFloat = 760
  static let menuStep: CGFloat = 80
  static let menuInset: CGFloat = 60
  static let menuRadius: CGFloat = 36
  static let menuPadding: CGFloat = 16
  static let headerTop: CGFloat = 14
  static let headerBottom: CGFloat = 8
  static let separatorInset: CGFloat = 16
  static let rowHeight: CGFloat = 64
  static let rowPadding: CGFloat = 24
  static let checkSize: CGFloat = 28
  static let checkColumn: CGFloat = 30
  static let checkGap: CGFloat = 18
  static let badgeSize: CGFloat = 160
  static let pauseSymbol: CGFloat = 72
  static let skipSymbol: CGFloat = 72
  static let badgeInset: CGFloat = 160
  static let menuGap: CGFloat = 30
  static let rowsMaxHeight: CGFloat = 640
  static let scrim = 0.35
  static let dimmed = Color(white: 1 - scrim)
}
