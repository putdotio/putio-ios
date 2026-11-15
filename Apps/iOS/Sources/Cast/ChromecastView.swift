import PutioCore
import SwiftUI
import UIKit

struct PutioCastButton: View {
  let model: PutioCastModel
  @Environment(\.putioVideoControlsHold) private var holdControls
  @State private var holdsControls = false

  var body: some View {
    if model.showsCastButton {
      Button {
        model.castButtonTapped()
      } label: {
        PutioRouteButtonLabel(
          icon: model.isConnected ? .screencastFill : .screencast, isActive: model.isConnected)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        model.isConnected ? String(localized: "Cast, connected") : String(localized: "Cast")
      )
      .accessibilityIdentifier("cast.button")
      .anchorPreference(key: PutioCastButtonAnchor.self, value: .bounds) { $0 }
      .onChange(of: model.presentsPicker || model.presentsLocalNetworkAlert, initial: true) {
        _, held in
        guard held || holdsControls else { return }
        holdsControls = held
        holdControls(held)
      }
      .onDisappear {
        guard holdsControls else { return }
        holdsControls = false
        holdControls(false)
      }
    }
  }
}

private struct PutioCastButtonAnchor: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}

extension View {
  func putioCastPicker(_ model: PutioCastModel) -> some View {
    modifier(PutioCastPickerPresentation(model: model))
  }
}

private struct PutioCastPickerPresentation: ViewModifier {
  @Bindable var model: PutioCastModel
  @State private var buttonFrame: CGRect?

  func body(content: Content) -> some View {
    content.overlayPreferenceValue(PutioCastButtonAnchor.self) { anchor in
      GeometryReader { proxy in
        Color.clear
          .onChange(of: anchor.map { proxy[$0] }, initial: true) { _, frame in
            if let frame { buttonFrame = frame }
          }
          .popover(
            isPresented: $model.presentsPicker,
            attachmentAnchor: buttonFrame.map { .rect(.rect($0)) } ?? .point(.topTrailing),
            arrowEdge: .top
          ) {
            PutioCastPicker(model: model)
              .presentationCompactAdaptation(.sheet)
          }
      }
    }
    .onDisappear { model.presentsPicker = false }
  }
}

struct PutioCastPicker: View {
  let model: PutioCastModel

  var body: some View {
    PutioSheetScaffold(
      title: String(localized: "Cast to"),
      dismissButton: nil,
      trailingButton: PutioSheetIconButton(icon: .x, label: String(localized: "Close")) {
        model.presentsPicker = false
      }
    ) {
      List {
        ForEach(model.discovery.devices) { device in
          Button {
            model.choose(device)
          } label: {
            PutioCastPickerRow(
              icon: device.icon, title: device.name,
              supporting: device.audioOnly ? String(localized: "Audio only") : device.model,
              isSelected: device.isSelected)
          }
          .buttonStyle(.plain)
          .pickerRow(
            isFirst: device.id == model.discovery.devices.first?.id,
            isLast: isLast(.device(device.id))
          )
          .accessibilityAddTraits(device.isSelected ? .isSelected : [])
          .accessibilityIdentifier("cast.picker.device.\(device.id)")
        }
        if showsStop {
          Button {
            model.stopCastingFromPicker()
          } label: {
            PutioCastPickerRow(icon: .stopCircle, title: String(localized: "Stop casting"))
          }
          .buttonStyle(.plain)
          .pickerRow(isFirst: model.discovery.devices.isEmpty, isLast: isLast(.stop))
          .accessibilityIdentifier("cast.picker.stop")
        }
        if model.discovery.isSearching {
          PutioCastPickerRow(title: String(localized: "Looking for devices…"))
            .pickerRow(isFirst: model.discovery.devices.isEmpty && !showsStop, isLast: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("cast.picker.searching")
        }
      }
      .listStyle(.plain)
      .accessibilityIdentifier("cast.picker")
    }
    .presentationDetents([.medium, .large])
    .frame(minWidth: 320, idealWidth: 375, minHeight: 280, idealHeight: 360)
    .preferredColorScheme(.dark)
  }

  private enum Row: Equatable {
    case device(PutioCastDevice.ID)
    case stop
  }

  private var showsStop: Bool { model.connection.deviceName != nil }

  private func isLast(_ row: Row) -> Bool {
    guard !model.discovery.isSearching else { return false }
    if showsStop { return row == .stop }
    return row == model.discovery.devices.last.map { .device($0.id) }
  }
}

extension View {
  fileprivate func pickerRow(isFirst: Bool = false, isLast: Bool) -> some View {
    var hidden: VerticalEdge.Set = []
    if isFirst { hidden.insert(.top) }
    if isLast { hidden.insert(.bottom) }
    return listRowBackground(Color.clear).listRowSeparator(.hidden, edges: hidden)
  }
}

private struct PutioCastPickerRow: View {
  var icon: PutioIcon?
  let title: String
  var supporting: String?
  var isSelected = false

  var body: some View {
    HStack(spacing: PutioTheme.Spacing.space4) {
      Group {
        if let icon {
          Image(putioIcon: icon)
            .resizable()
            .scaledToFit()
            .foregroundStyle(PutioTheme.Colors.textSecondary)
        } else {
          ProgressView()
            .tint(PutioTheme.Colors.textSecondary)
        }
      }
      .frame(width: PutioCastPickerMetrics.icon, height: PutioCastPickerMetrics.icon)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .putioFont(PutioTheme.Typography.body)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
        if let supporting {
          Text(supporting)
            .putioFont(PutioTheme.Typography.caption)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
        }
      }
      Spacer(minLength: 0)
      if isSelected {
        Image(putioIcon: .check)
          .resizable()
          .scaledToFit()
          .frame(width: PutioCastPickerMetrics.icon, height: PutioCastPickerMetrics.icon)
          .foregroundStyle(PutioTheme.Colors.accent)
          .accessibilityHidden(true)
      }
    }
    .frame(minHeight: PutioCastPickerMetrics.row)
    .contentShape(Rectangle())
  }
}

private enum PutioCastPickerMetrics {
  static let icon: CGFloat = 24
  static let row: CGFloat = 40
}

extension PutioCastDevice {
  fileprivate var icon: PutioIcon {
    switch kind {
    case .tv, .other: .televisionSimple
    case .speaker: .speakerHiFi
    }
  }
}

struct PutioRouteButtonLabel: View {
  let icon: PutioIcon
  var isActive = false

  var body: some View {
    Image(putioIcon: icon)
      .resizable()
      .scaledToFit()
      .frame(width: PutioRouteButtonMetrics.icon, height: PutioRouteButtonMetrics.icon)
      .foregroundStyle(isActive ? PutioTheme.Colors.accent : .white)
      .frame(width: PutioRouteButtonMetrics.target, height: PutioRouteButtonMetrics.target)
      .contentShape(Rectangle())
  }
}

enum PutioRouteButtonMetrics {
  static let icon: CGFloat = 20
  static let target: CGFloat = 44
}

extension View {
  func putioCastLocalNetworkAlert(_ model: PutioCastModel, isActive: Bool = true) -> some View {
    modifier(PutioCastLocalNetworkAlert(model: model, isActive: isActive))
  }
}

private struct PutioCastLocalNetworkAlert: ViewModifier {
  let model: PutioCastModel
  let isActive: Bool

  func body(content: Content) -> some View {
    content.putioAlert(
      String(localized: "Local network access is off"),
      isPresented: Binding(
        get: { isActive && model.presentsLocalNetworkAlert },
        set: { if !$0 { model.presentsLocalNetworkAlert = false } }),
      message: String(localized: "Turn it on in Settings to find Cast devices."),
      actions: [
        PutioAlertAction(
          String(localized: "Cancel"), tier: .cancel, id: "cast.local-network.cancel"),
        PutioAlertAction(
          String(localized: "Open Settings"), tier: .primary, id: "cast.local-network.settings"
        ) {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
          }
        },
      ])
  }
}

/// The persistent bar above the tab bar while a receiver has something of
/// ours: title, status, play and pause, and the way back to the player.
struct PutioCastBar: View {
  let model: PutioCastModel
  let onOpen: () -> Void

  var body: some View {
    HStack(spacing: PutioTheme.Spacing.space3) {
      Image(systemName: "tv")
        .foregroundStyle(PutioTheme.Colors.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: model.currentTitle ?? "")
          .putioFont(PutioTheme.Typography.body)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .lineLimit(1)
          .accessibilityIdentifier("cast.bar.title")
        Text(barSubtitle)
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .lineLimit(1)
          .accessibilityIdentifier("cast.bar.status")
      }
      Spacer(minLength: PutioTheme.Spacing.space2)
      if model.phase == .playing {
        Button {
          model.togglePlayback()
        } label: {
          Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            .font(.title3)
        }
        .accessibilityLabel(
          model.isPlaying ? String(localized: "Pause") : String(localized: "Play")
        )
        .accessibilityIdentifier("cast.bar.toggle")
      } else if case .failed = model.phase {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(PutioTheme.Colors.destructive)
      } else {
        ProgressView()
      }
    }
    .padding(.horizontal, PutioTheme.Spacing.space4)
    .padding(.vertical, PutioTheme.Spacing.space3)
    .background(PutioTheme.Colors.surface)
    .contentShape(Rectangle())
    .onTapGesture(perform: onOpen)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("cast.bar")
  }

  private var barSubtitle: String {
    let device = model.connection.deviceName ?? String(localized: "Chromecast")
    switch model.phase {
    case .failed: return String(localized: "Can’t play this on \(device).")
    case .playing: return String(localized: "Playing on \(device)")
    case .loading, nil: return String(localized: "Loading on \(device)")
    }
  }
}
