#if os(iOS) || os(watchOS)
  import SwiftUI

  public struct PutioNumericText: View {
    private let text: String
    @PutioScaledMetric private var size: CGFloat

    public init(_ text: String) {
      self.text = text
      _size = PutioScaledMetric(PutioNumericTextLayout.size)
    }

    public var body: some View {
      Text(Self.spaced(text, size: size))
        .putioFont(PutioTheme.Typography.numeric)
    }

    static func spaced(_ text: String, size: CGFloat) -> AttributedString {
      var string = AttributedString(text)
      string.kern = size * PutioNumericTextLayout.tracking
      var index = string.characters.startIndex
      while index < string.characters.endIndex {
        let next = string.characters.index(after: index)
        if string.characters[index].isWhitespace {
          string[index..<next].kern =
            size * (PutioNumericTextLayout.tracking + PutioNumericTextLayout.wordSpacing)
        }
        index = next
      }
      return string
    }
  }

  enum PutioNumericTextLayout {
    static let size = PutioMetricRole(
      value: PutioTheme.Typography.mono.size, relativeTo: PutioTheme.Typography.mono.textStyle)
    static let tracking: CGFloat = -0.01
    static let wordSpacing: CGFloat = -0.25
  }
#endif
