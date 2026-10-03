import PutioCore
import SwiftUI

#if DEBUG
  struct HarnessAccessibilityConfiguration: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
      if enabled {
        content
          .overlay { HarnessAccessibilityProbe() }
          .background { HarnessAccessibilityTraits().frame(width: 0, height: 0) }
      } else {
        content
      }
    }
  }

  private struct HarnessAccessibilityTraits: UIViewRepresentable {
    func makeUIView(context: Context) -> TraitView { TraitView() }
    func updateUIView(_ view: TraitView, context: Context) {}

    final class TraitView: UIView {
      override func didMoveToWindow() {
        super.didMoveToWindow()
        window?.windowScene?.traitOverrides.preferredContentSizeCategory =
          .accessibilityExtraExtraExtraLarge
      }
    }
  }

  private struct HarnessAccessibilityProbe: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityLabel("Accessibility settings")
        .accessibilityValue("text=\(textSize);reduce-motion=\(reduceMotion)")
        .accessibilityIdentifier("harness.accessibility")
        .allowsHitTesting(false)
    }
  }

  struct HarnessRatingLinkCapture: ViewModifier {
    let enabled: Bool
    @State private var openedURLs: [URL] = []

    func body(content: Content) -> some View {
      if enabled {
        content
          .environment(
            \.openURL,
            OpenURLAction { url in
              openedURLs.append(url)
              return .handled
            }
          )
          .overlay {
            Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement()
              .accessibilityLabel("External link requests")
              .accessibilityValue(
                "\(openedURLs.count)|\(openedURLs.last?.absoluteString ?? "")"
              )
              .accessibilityIdentifier("account.rating-link-requests")
              .allowsHitTesting(false)
          }
      } else {
        content
      }
    }
  }
#endif

// The fixed harness exercise contract: relaunch into accessibility Dynamic
// Type, write the semantic marker, and render the typography proof content.
struct HarnessExerciseView: View {
  var body: some View {
    SignedOutProofView(
      presentation: .harnessInitialPresentation(arguments: [
        "--putio-harness-scenario", "exercised",
      ])
    )
    .dynamicTypeSize(.accessibility3)
    .onAppear {
      SignedOutPresentation.signalHarnessExercise()
    }
  }
}

private struct SignedOutProofView: View {
  @PutioScaledMetric(PutioTheme.ScaledMetrics.contentGap) private var contentGap

  let presentation: SignedOutPresentation

  var body: some View {
    ScrollView {
      content.padding(PutioTheme.Spacing.space4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PutioTheme.Colors.background)
  }

  private var content: some View {
    VStack(spacing: contentGap) {
      Image(systemName: "externaldrive.fill")
        .putioIcon(PutioTheme.Icons.button)
        .foregroundStyle(PutioTheme.Colors.accent)
      Text(presentation.title)
        .putioFont(PutioTheme.Typography.title)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
      Text(presentation.message)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
      ForEach(TypographyHarnessProof.hostileFilenames, id: \.self) { filename in
        Text(filename)
          .putioFont(PutioTheme.Typography.mono)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
      }
      Text(TypographyHarnessProof.numericSample)
        .putioFont(PutioTheme.Typography.numeric)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
    }
  }
}
