import AVFoundation
import CoreMedia
import PutioCore
import SwiftUI

@MainActor
final class PutioVideoCaptionFeed: NSObject, AVPlayerItemLegibleOutputPushDelegate {
  private let output = AVPlayerItemLegibleOutput()
  private weak var item: AVPlayerItem?
  private var changes = PutioSubtitleChanges<PutioVideoCue>()
  private var nextID = 0

  override init() {
    super.init()
    output.setDelegate(self, queue: .main)
    output.advanceIntervalForDelegateInvocation = PutioSubtitleTiming.limitSeconds + 1
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

  func clear() {
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
