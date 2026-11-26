#if canImport(AetherEngine)
  import AVFoundation
  import AetherEngine
  import MediaAccessibility
  import PutioCore
  import SwiftUI

  struct PutioVideoCue: Identifiable, Equatable {
    let id: Int
    let text: AttributedString?
    let image: CGImage?
    let position: CGRect?
    let canvas: CGSize

    init(_ cue: SubtitleCue) {
      id = cue.id
      text = cue.text.map(AttributedString.init)
      if case .image(let image) = cue.body {
        self.image = image.cgImage
        position = image.position
        canvas = image.canvasSize
      } else {
        image = nil
        position = nil
        canvas = .zero
      }
    }

    init(id: Int, text: AttributedString) {
      self.id = id
      self.text = text
      image = nil
      position = nil
      canvas = .zero
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.id == rhs.id && lhs.text == rhs.text
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

  struct PutioVideoPicture: Equatable {
    static let unknown = PutioVideoPicture(coded: .zero, display: .zero)

    let coded: CGSize
    let display: CGSize

    func rect(in bounds: CGRect) -> CGRect {
      guard display.width > 0, display.height > 0 else { return bounds }
      return AVMakeRect(aspectRatio: display, insideRect: bounds)
    }

    func frame(ofBitmapAt position: CGRect, canvas: CGSize, in bounds: CGRect) -> CGRect {
      let picture = rect(in: bounds)
      let placed = Self.normalizedOnCodedFrame(position, canvas: canvas, coded: coded)
      return CGRect(
        x: picture.minX + placed.minX * picture.width,
        y: picture.minY + placed.minY * picture.height,
        width: placed.width * picture.width,
        height: placed.height * picture.height)
    }

    private static func normalizedOnCodedFrame(
      _ position: CGRect, canvas: CGSize, coded: CGSize
    ) -> CGRect {
      guard canvas.width > 0, canvas.height > 0, coded.width > 0, coded.height > 0 else {
        return position
      }
      let scale = coded.width / canvas.width
      let top = coded.height / 2 + (position.minY - 0.5) * canvas.height * scale
      return CGRect(
        x: position.minX,
        y: top / coded.height,
        width: position.width,
        height: position.height * canvas.height * scale / coded.height)
    }
  }

  struct PutioVideoSubtitleOverlay: View {
    let cues: [PutioVideoCue]
    let size: PutioSubtitleTextSize
    let picture: PutioVideoPicture
    let bottomInset: CGFloat

    @State private var appearance = PutioCaptionAppearance.current
    @ScaledMetric private var baseSize: CGFloat

    init(
      cues: [PutioVideoCue], size: PutioSubtitleTextSize, picture: PutioVideoPicture = .unknown,
      bottomInset: CGFloat = PutioTheme.Spacing.space6,
      baseSize: CGFloat = PutioTheme.Typography.sizeBase
    ) {
      self.cues = cues
      self.size = size
      self.picture = picture
      self.bottomInset = bottomInset
      _baseSize = ScaledMetric(wrappedValue: baseSize, relativeTo: .body)
    }

    var body: some View {
      ZStack {
        GeometryReader { geometry in
          let bounds = CGRect(origin: .zero, size: geometry.size)
          ForEach(cues) { cue in
            if let image = cue.image, let position = cue.position {
              let frame = picture.frame(ofBitmapAt: position, canvas: cue.canvas, in: bounds)
              Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            }
          }
        }
        .ignoresSafeArea()
        ZStack(alignment: .bottom) {
          let texts = cues.compactMap { cue in cue.text.flatMap { $0.characters.isEmpty ? nil : $0 }
          }
          if !texts.isEmpty {
            caption(texts)
              .padding(.horizontal, PutioTheme.Spacing.space4)
              .padding(.bottom, bottomInset)
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
#endif
