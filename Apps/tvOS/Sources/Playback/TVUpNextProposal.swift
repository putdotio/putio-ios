import AVKit
import PutioCore
import SwiftUI

struct TVUpNextProposal {
  let next: PutioNextVideo
  let folderName: String?
  let model: PutioVideoUpNextModel
  let accept: @MainActor () -> Void
  let reject: @MainActor () -> Void
}

final class TVUpNextProposalController: AVContentProposalViewController {
  private let host = UIHostingController<AnyView?>(rootView: nil)
  var willAccept: @MainActor () -> Void = {}

  func show(_ proposal: TVUpNextProposal) {
    host.rootView = AnyView(
      TVUpNextModelCard(
        next: proposal.next, folderName: proposal.folderName, model: proposal.model,
        play: { [weak self] in
          self?.willAccept()
          self?.dismissContentProposal(for: .accept, animated: true)
        },
        close: { [weak self] in self?.dismissContentProposal(for: .reject, animated: true) }))
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    host.view.backgroundColor = .clear
    addChild(host)
    host.view.frame = view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(host.view)
    host.didMove(toParent: self)
  }

  override var preferredPlayerViewFrame: CGRect { view.bounds }

  override var preferredFocusEnvironments: [any UIFocusEnvironment] { [host] }
}

@MainActor
final class TVUpNextProposalDelegate: NSObject, AVPlayerViewControllerDelegate {
  var proposal: TVUpNextProposal?

  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    shouldPresent proposal: AVContentProposal
  ) -> Bool {
    self.proposal != nil
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController, didAccept proposal: AVContentProposal
  ) {
    self.proposal?.accept()
  }

  func playerViewController(
    _ playerViewController: AVPlayerViewController, didReject proposal: AVContentProposal
  ) {
    self.proposal?.reject()
  }
}

private struct TVUpNextModelCard: View {
  let next: PutioNextVideo
  let folderName: String?
  let model: PutioVideoUpNextModel
  let play: () -> Void
  let close: () -> Void

  var body: some View {
    let secondsLeft: Int? =
      if case .countingDown(_, let secondsLeft) = model.state { secondsLeft } else { nil }
    TVUpNextCard(
      next: next, folderName: folderName, secondsLeft: secondsLeft, play: play, close: close)
  }
}

struct TVUpNextCard: View {
  let next: PutioNextVideo
  let folderName: String?
  let secondsLeft: Int?
  let play: () -> Void
  let close: () -> Void

  private enum Action { case play, close }
  @FocusState private var focusedAction: Action?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(heading)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .lineLimit(1)
      Text(next.name)
        .putioFont(PutioTheme.TV.Typography.body)
        .fontWeight(.semibold)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .lineLimit(2)
        .padding(.top, PutioTheme.TV.Spacing.xs)
        .accessibilityLabel(String(localized: "Up next, \(next.name)", bundle: .putioCore))
        .accessibilityIdentifier("video.next-title")
      if let secondsLeft {
        Text(String(localized: "Playing in \(secondsLeft)", bundle: .putioCore))
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          .monospacedDigit()
          .padding(.top, PutioTheme.TV.Spacing.xs)
          .accessibilityIdentifier("video.next-countdown")
        TVUpNextCountdownBar(secondsLeft: secondsLeft)
          .padding(.top, PutioTheme.TV.Spacing.small)
      }
      HStack(spacing: PutioTheme.TV.Spacing.small) {
        Button(action: play) {
          Label(
            secondsLeft == nil
              ? String(localized: "Play next", bundle: .putioCore)
              : String(localized: "Play now", bundle: .putioCore),
            systemImage: "play.fill")
        }
        .focused($focusedAction, equals: .play)
        .accessibilityIdentifier("video.play-next")
        Button(
          secondsLeft == nil
            ? String(localized: "Close", bundle: .putioCore)
            : String(localized: "Cancel", bundle: .putioCore),
          action: close
        )
        .focused($focusedAction, equals: .close)
        .accessibilityIdentifier("video.cancel-next")
      }
      .putioFont(PutioTheme.TV.Typography.body)
      .buttonStyle(.bordered)
      .padding(.top, PutioTheme.TV.Spacing.medium)
      .focusSection()
    }
    .padding(PutioTheme.TV.Spacing.medium)
    .frame(width: TVUpNextCardLayout.width, alignment: .leading)
    .background(
      PutioTheme.Colors.surface.opacity(TVUpNextCardLayout.backgroundOpacity),
      in: RoundedRectangle(cornerRadius: TVUpNextCardLayout.radius)
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    .padding(.bottom, TVUpNextCardLayout.bottomInset)
    .tvOverscanPadding()
    .defaultFocus($focusedAction, .play)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("video.up-next")
  }

  private var heading: String {
    guard let folderName else { return String(localized: "Up next", bundle: .putioCore) }
    return String(localized: "Up next in \(folderName)", bundle: .putioCore)
  }
}

private struct TVUpNextCountdownBar: View {
  let secondsLeft: Int

  private var fraction: Double {
    let total = Double(PutioVideoUpNextModel.countdown.components.seconds)
    guard total > 0 else { return 1 }
    return min(1, max(0, 1 - Double(secondsLeft) / total))
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(PutioTheme.TV.Colors.textTertiary.opacity(0.4))
        Capsule()
          .fill(PutioTheme.Colors.accent)
          .frame(width: proxy.size.width * fraction)
      }
    }
    .frame(height: TVUpNextCardLayout.progressHeight)
    .animation(.linear(duration: 1), value: fraction)
    .accessibilityHidden(true)
  }
}

enum TVUpNextCardLayout {
  static let width: CGFloat = 600
  static let radius: CGFloat = 32
  static let progressHeight: CGFloat = 4
  static let backgroundOpacity = 0.92
  static let bottomInset: CGFloat = 220
}
