import AVFoundation
import AetherEngine
import CoreMedia
import MediaAccessibility
import PutioCore
import SwiftUI

struct PutioVideoCue: Identifiable, Equatable {
  let id: Int
  let text: AttributedString?
  let image: CGImage?
  let position: CGRect?

  init(_ cue: SubtitleCue) {
    id = cue.id
    text = cue.text.map(AttributedString.init)
    if case .image(let image) = cue.body {
      self.image = image.cgImage
      position = image.position
    } else {
      image = nil
      position = nil
    }
  }

  init(id: Int, text: AttributedString) {
    self.id = id
    self.text = text
    image = nil
    position = nil
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.text == rhs.text
  }
}

@MainActor
final class PutioVideoCaptionFeed: NSObject, AVPlayerItemLegibleOutputPushDelegate {
  private let output = AVPlayerItemLegibleOutput()
  private weak var item: AVPlayerItem?
  private var changes = PutioSubtitleChanges<PutioVideoCue>()
  private var nextID = 0

  override init() {
    super.init()
    output.setDelegate(self, queue: .main)
    output.advanceIntervalForDelegateInvocation = PutioSubtitleTiming.limitSeconds
    output.textStylingResolution = .sourceAndRulesOnly
    output.suppressesPlayerRendering = true
  }

  var rendersNatively: Bool {
    get { !output.suppressesPlayerRendering }
    set { output.suppressesPlayerRendering = !newValue }
  }

  func attach(to item: AVPlayerItem) {
    guard self.item !== item else { return }
    detach()
    self.item = item
    item.add(output)
  }

  func detach() {
    if let item, item.outputs.contains(output) { item.remove(output) }
    item = nil
    changes.removeAll()
  }

  func restart() {
    changes.removeAll()
  }

  func cues(at time: Double, offset: Double) -> [PutioVideoCue] {
    changes.forget(before: time - PutioSubtitleTiming.limitSeconds)
    return changes.cues(at: time, offset: offset)
  }

  nonisolated func legibleOutput(
    _ output: AVPlayerItemLegibleOutput,
    didOutputAttributedStrings strings: [NSAttributedString],
    nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime
  ) {
    let texts = strings.map(Self.text)
    let seconds = itemTime.seconds
    MainActor.assumeIsolated { record(texts, at: seconds) }
  }

  private func record(_ texts: [AttributedString], at seconds: Double) {
    let cues = texts.filter { !$0.characters.isEmpty }.map { text in
      nextID &+= 1
      return PutioVideoCue(id: nextID, text: text)
    }
    changes.record(cues, at: seconds)
  }

  nonisolated static func text(_ string: NSAttributedString) -> AttributedString {
    var text = AttributedString()
    string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) {
      attributes, range, _ in
      var run = AttributedString(string.attributedSubstring(from: range).string)
      var intent: InlinePresentationIntent = []
      if Self.flag(attributes, kCMTextMarkupAttribute_ItalicStyle) { intent.insert(.emphasized) }
      if Self.flag(attributes, kCMTextMarkupAttribute_BoldStyle) {
        intent.insert(.stronglyEmphasized)
      }
      if !intent.isEmpty { run.inlinePresentationIntent = intent }
      if Self.flag(attributes, kCMTextMarkupAttribute_UnderlineStyle) {
        run.underlineStyle = .single
      }
      text += run
    }
    return text
  }

  private nonisolated static func flag(
    _ attributes: [NSAttributedString.Key: Any], _ key: CFString
  ) -> Bool {
    (attributes[NSAttributedString.Key(key as String)] as? Bool) ?? false
  }
}

struct PutioCaptionAppearance: Equatable {
  var fontName: String?
  var foreground: Color
  var background: Color
  var window: Color
  var windowRadius: CGFloat
  var relativeSize: CGFloat
  var edge: MACaptionAppearanceTextEdgeStyle

  static var current: PutioCaptionAppearance {
    let domain = MACaptionAppearanceDomain.user
    let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(domain, nil, .default)
      .takeRetainedValue()
    return PutioCaptionAppearance(
      fontName: CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
      foreground: Color(
        cgColor: MACaptionAppearanceCopyForegroundColor(domain, nil)
          .takeRetainedValue()
      )
      .opacity(MACaptionAppearanceGetForegroundOpacity(domain, nil)),
      background: Color(
        cgColor: MACaptionAppearanceCopyBackgroundColor(domain, nil)
          .takeRetainedValue()
      )
      .opacity(MACaptionAppearanceGetBackgroundOpacity(domain, nil)),
      window: Color(cgColor: MACaptionAppearanceCopyWindowColor(domain, nil).takeRetainedValue())
        .opacity(MACaptionAppearanceGetWindowOpacity(domain, nil)),
      windowRadius: MACaptionAppearanceGetWindowRoundedCornerRadius(domain, nil),
      relativeSize: MACaptionAppearanceGetRelativeCharacterSize(domain, nil),
      edge: MACaptionAppearanceGetTextEdgeStyle(domain, nil))
  }
}

struct PutioVideoSubtitleOverlay: View {
  let cues: [PutioVideoCue]
  let size: PutioSubtitleTextSize

  @State private var appearance = PutioCaptionAppearance.current
  @ScaledMetric(relativeTo: .body) private var baseSize = PutioTheme.Typography.sizeBase

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .bottom) {
        ForEach(cues) { cue in
          if let image = cue.image, let position = cue.position {
            Image(decorative: image, scale: 1)
              .resizable()
              .frame(
                width: position.width * geometry.size.width,
                height: position.height * geometry.size.height
              )
              .position(
                x: position.midX * geometry.size.width, y: position.midY * geometry.size.height)
          }
        }
        let texts = cues.compactMap { cue in cue.text.flatMap { $0.characters.isEmpty ? nil : $0 } }
        if !texts.isEmpty {
          caption(texts)
            .padding(.horizontal, PutioTheme.Spacing.space4)
            .padding(.bottom, PutioTheme.Spacing.space6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
      }
    }
    .allowsHitTesting(false)
    .task {
      let changes = NotificationCenter.default.notifications(
        named: Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String))
      for await _ in changes {
        appearance = .current
      }
    }
  }

  private func caption(_ texts: [AttributedString]) -> some View {
    let pointSize = baseSize * appearance.relativeSize * size.scale
    let font =
      appearance.fontName.map { Font.custom($0, fixedSize: pointSize) }
      ?? .system(size: pointSize)
    return VStack(spacing: 0) {
      ForEach(texts.indices, id: \.self) { index in
        Text(texts[index])
          .font(font)
          .foregroundStyle(appearance.foreground)
          .multilineTextAlignment(.center)
          .padding(.horizontal, pointSize * 0.25)
          .background(appearance.background)
      }
    }
    .padding(pointSize * 0.25)
    .background(
      appearance.window, in: RoundedRectangle(cornerRadius: appearance.windowRadius)
    )
    .modifier(PutioCaptionEdge(edge: appearance.edge))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("video.subtitle-cue")
  }
}

private struct PutioCaptionEdge: ViewModifier {
  let edge: MACaptionAppearanceTextEdgeStyle

  func body(content: Content) -> some View {
    switch edge {
    case .raised:
      content.shadow(color: .black, radius: 0, x: 1, y: 1)
    case .depressed:
      content.shadow(color: .black, radius: 0, x: -1, y: -1)
    case .uniform:
      content.shadow(color: .black, radius: 1).shadow(color: .black, radius: 1)
    case .dropShadow:
      content.shadow(color: .black, radius: 2, x: 1, y: 1)
    default:
      content
    }
  }
}

extension PutioSubtitleSizeMemory {
  static func video() -> PutioSubtitleSizeMemory {
    #if DEBUG
      HarnessSubtitleSize.resetOnLaunch(.standard)
    #endif
    return PutioSubtitleSizeMemory()
  }
}

extension PutioSubtitleTextSize {
  var title: String {
    switch self {
    case .small: String(localized: "Small")
    case .medium: String(localized: "Medium")
    case .large: String(localized: "Large")
    case .extraLarge: String(localized: "Extra large")
    }
  }
}
