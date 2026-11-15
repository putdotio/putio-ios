import PutioCore
import SwiftUI

struct PutioVideoUpNext {
  enum Offer {
    case chip(busy: Bool)
    case card(name: String, secondsLeft: Int)
  }

  let offer: Offer
  let onPlay: () -> Void
  let onCancel: () -> Void

  var showsCard: Bool {
    if case .card = offer { return true }
    return false
  }
}

struct PutioVideoUpNextAccessory: View {
  let upNext: PutioVideoUpNext
  let iconOnly: Bool

  var body: some View {
    switch upNext.offer {
    case .chip(let busy):
      Button(action: upNext.onPlay) {
        PutioVideoChipLabel(
          icon: .skipForward, title: String(localized: "Next episode"), iconOnly: iconOnly)
      }
      .buttonStyle(.plain)
      .disabled(busy)
      .accessibilityLabel(String(localized: "Next episode"))
      .accessibilityIdentifier("video.next-episode")
    case .card(let name, let secondsLeft):
      PutioVideoUpNextCard(
        name: name, secondsLeft: secondsLeft, onPlay: upNext.onPlay, onCancel: upNext.onCancel)
    }
  }
}

private struct PutioVideoUpNextCard: View {
  let name: String
  let secondsLeft: Int
  let onPlay: () -> Void
  let onCancel: () -> Void

  @ScaledMetric(relativeTo: .body) private var headingMinWidth: CGFloat = 140
  @ScaledMetric(relativeTo: .body) private var headingMaxWidth: CGFloat = 180

  var body: some View {
    PutioUpNextCardLayout(
      spacing: PutioTheme.Spacing.space3, rowSpacing: PutioTheme.Spacing.space2,
      headingMinWidth: headingMinWidth, headingMaxWidth: headingMaxWidth
    ) {
      Text("Up next in \(countdown)")
        .putioFont(PutioTheme.Typography.caption)
        .foregroundStyle(.white.opacity(0.6))
        .monospacedDigit()
        .accessibilityIdentifier("video.next-countdown")
      Text(name)
        .putioFont(PutioVideoMetrics.titleFont)
        .foregroundStyle(.white)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityIdentifier("video.next-title")
      actions
    }
    .padding(.leading, PutioTheme.Spacing.space3)
    .padding([.trailing, .vertical], PutioUpNextMetrics.inset)
    .background(
      Color.black.opacity(0.75),
      in: RoundedRectangle(cornerRadius: PutioUpNextMetrics.radius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: PutioUpNextMetrics.radius, style: .continuous)
        .strokeBorder(Color.white.opacity(0.07), lineWidth: PutioTheme.Border.width)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("video.up-next")
  }

  private var actions: some View {
    HStack(spacing: PutioTheme.Spacing.space2) {
      Button(action: onCancel) {
        label(String(localized: "Cancel"), prominent: false)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("video.cancel-next")
      Button(action: onPlay) {
        label(String(localized: "Play next"), prominent: true)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("video.play-next")
    }
    .fixedSize()
  }

  private var countdown: String {
    Duration.seconds(secondsLeft).formatted(.units(allowed: [.seconds], width: .wide))
  }

  private func label(_ title: String, prominent: Bool) -> some View {
    Text(title)
      .putioFont(PutioTheme.Components.Button.label)
      .lineLimit(1)
      .foregroundStyle(prominent ? PutioTheme.Components.Button.primaryForeground : .white)
      .padding(.horizontal, PutioVideoMetrics.chipPadding)
      .frame(minHeight: PutioUpNextMetrics.buttonHeight)
      .background(
        prominent ? PutioTheme.Colors.accent : Color.white.opacity(0.12), in: Capsule()
      )
      .contentShape(Capsule())
  }
}

private struct PutioUpNextCardLayout: Layout {
  let spacing: CGFloat
  let rowSpacing: CGFloat
  let headingMinWidth: CGFloat
  let headingMaxWidth: CGFloat
  var lineSpacing = PutioTheme.Spacing.space1

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 3 else { return .zero }
    let countdown = subviews[0].sizeThatFits(.unspecified)
    let nameIdeal = subviews[1].sizeThatFits(.unspecified).width
    let actions = subviews[2].sizeThatFits(.unspecified)
    let headingWidth = max(
      countdown.width, min(max(headingMinWidth, nameIdeal), headingMaxWidth))
    let desired = headingWidth + spacing + actions.width
    let available = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? desired
    if fitsInOneRow(available, countdown: countdown, actions: actions) {
      let width = min(available, desired)
      let heading = headingHeight(width - spacing - actions.width, subviews)
      return CGSize(width: width, height: max(heading, actions.height))
    }
    let width = max(min(available, max(countdown.width, nameIdeal)), actions.width)
    return CGSize(
      width: width, height: headingHeight(width, subviews) + rowSpacing + actions.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard subviews.count == 3 else { return }
    let countdown = subviews[0].sizeThatFits(.unspecified)
    let actions = subviews[2].sizeThatFits(.unspecified)
    if fitsInOneRow(bounds.width, countdown: countdown, actions: actions) {
      let headingWidth = bounds.width - spacing - actions.width
      let height = headingHeight(headingWidth, subviews)
      placeHeading(
        at: CGPoint(x: bounds.minX, y: bounds.midY - height / 2), width: headingWidth, subviews)
      subviews[2].place(
        at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
      return
    }
    placeHeading(at: bounds.origin, width: bounds.width, subviews)
    subviews[2].place(
      at: CGPoint(
        x: bounds.minX, y: bounds.minY + headingHeight(bounds.width, subviews) + rowSpacing),
      anchor: .topLeading, proposal: .unspecified)
  }

  private func headingHeight(_ width: CGFloat, _ subviews: Subviews) -> CGFloat {
    let line = ProposedViewSize(width: width, height: nil)
    return subviews[0].sizeThatFits(line).height + lineSpacing
      + subviews[1].sizeThatFits(line).height
  }

  private func placeHeading(at origin: CGPoint, width: CGFloat, _ subviews: Subviews) {
    let line = ProposedViewSize(width: width, height: nil)
    subviews[0].place(at: origin, anchor: .topLeading, proposal: line)
    subviews[1].place(
      at: CGPoint(x: origin.x, y: origin.y + subviews[0].sizeThatFits(line).height + lineSpacing),
      anchor: .topLeading, proposal: line)
  }

  private func fitsInOneRow(_ width: CGFloat, countdown: CGSize, actions: CGSize) -> Bool {
    width >= max(headingMinWidth, countdown.width) + spacing + actions.width
  }
}

private enum PutioUpNextMetrics {
  static let radius: CGFloat = 22
  static let inset: CGFloat = 12
  static let buttonHeight: CGFloat = 38
}
