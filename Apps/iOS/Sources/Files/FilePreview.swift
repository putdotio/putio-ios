import ImageIO
import Observation
import PDFKit
import PutioCore
import SwiftUI
import UIKit

enum PutioPreviewState: Equatable {
  case loading
  case image(UIImage)
  case document(PDFDocument)
  case text(PutioTextPreview)
  case failed(PutioPreviewFailure)

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.loading, .loading): true
    case (.image(let left), .image(let right)): left === right
    case (.document(let left), .document(let right)): left === right
    case (.text(let left), .text(let right)): left == right
    case (.failed(let left), .failed(let right)): left == right
    default: false
    }
  }
}

enum PutioPreviewFailure: Equatable {
  case loadFailed
  case cannotShow

  static func resolving(_ error: Error) -> Self? {
    if error is PutioPreviewTooLargeError { return .cannotShow }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: return nil
    default: return .loadFailed
    }
  }
}

enum PutioViewerRoute: Identifiable, Equatable {
  case preview(PutioPreviewRoute)
  case cannotShow(id: PutioFileID, title: String)

  init?(opening action: PutioFileOpenAction) {
    switch action {
    case .video, .audio:
      return nil
    case .preview(let route) where route.exceedsSizeCap:
      self = .cannotShow(id: route.id, title: route.title)
    case .preview(let route):
      self = .preview(route)
    case .unsupported(let route):
      self = .cannotShow(id: route.id, title: route.item.name)
    }
  }

  var id: PutioFileID {
    switch self {
    case .preview(let route): route.id
    case .cannotShow(let id, _): id
    }
  }

  var title: String {
    switch self {
    case .preview(let route): route.title
    case .cannotShow(_, let title): title
    }
  }
}

typealias PutioPreviewDownload = @MainActor @Sendable (PutioPreviewRoute) async throws -> Data

struct PutioPreviewTooLargeError: Error {}

private struct PutioPreviewRangeNotSatisfiable: Error {}

/// Downloads a preview body with a hard byte cap so a large original cannot
/// exhaust memory. The response is inspected before any body arrives and the
/// task is cancelled the moment the cap is crossed. Larger files stay on
/// put.io. 401/403 surface as session loss so the signed-out shell takes over.
enum PutioPreviewDownloader {
  static let maximumBytes = Int(PutioPreviewRoute.maximumBytes)

  static func download(
    _ url: URL,
    limit: Int = maximumBytes,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> Data {
    try await fetch(
      URLRequest(url: url), limit: limit, keepsPrefix: false, configuration: configuration)
  }

  static func downloadPrefix(
    _ url: URL,
    byteCount: Int,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue("bytes=0-\(byteCount - 1)", forHTTPHeaderField: "range")
    do {
      return try await fetch(
        request, limit: byteCount, keepsPrefix: true, configuration: configuration)
    } catch is PutioPreviewRangeNotSatisfiable {
      return Data()
    }
  }

  private static func fetch(
    _ request: URLRequest,
    limit: Int,
    keepsPrefix: Bool,
    configuration: URLSessionConfiguration
  ) async throws -> Data {
    let collector = PutioBoundedBodyCollector(limit: limit, keepsPrefix: keepsPrefix)
    let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (data, http) = try await collector.run(session.dataTask(with: request))
    switch http.statusCode {
    case 200...299: return data
    case 416 where keepsPrefix: throw PutioPreviewRangeNotSatisfiable()
    case 401, 403: throw PutioRuntimeError.sessionExpired
    case 404: throw PutioRuntimeError.notFound
    case 429: throw PutioRuntimeError.rateLimited
    case 408, 500...599: throw PutioRuntimeError.transient
    default: throw PutioRuntimeError.unknown
    }
  }
}

private final class PutioBoundedBodyCollector: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  private let limit: Int
  private let keepsPrefix: Bool
  private let lock = NSLock()
  private var body = Data()
  private var response: HTTPURLResponse?
  private var tooLarge = false
  private var prefixFilled = false
  private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

  init(limit: Int, keepsPrefix: Bool) {
    self.limit = limit
    self.keepsPrefix = keepsPrefix
  }

  func run(_ task: URLSessionDataTask) async throws -> (Data, HTTPURLResponse) {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock { self.continuation = continuation }
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      return
    }
    let oversized = !keepsPrefix && http.expectedContentLength > Int64(limit)
    lock.withLock {
      self.response = http
      if oversized { tooLarge = true }
    }
    completionHandler(oversized ? .cancel : .allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let exceeded = lock.withLock {
      // Nothing past the cap is ever buffered, including the chunk that trips it.
      guard !tooLarge, !prefixFilled else { return true }
      if body.count + data.count >= limit, keepsPrefix {
        body.append(data.prefix(limit - body.count))
        prefixFilled = true
        return true
      }
      if body.count + data.count > limit {
        tooLarge = true
        return true
      }
      body.append(data)
      return false
    }
    if exceeded { dataTask.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let (continuation, result):
      (CheckedContinuation<(Data, HTTPURLResponse), Error>?, Result<(Data, HTTPURLResponse), Error>) =
        lock.withLock {
          let continuation = self.continuation
          self.continuation = nil
          if tooLarge { return (continuation, .failure(PutioPreviewTooLargeError())) }
          if prefixFilled, let response { return (continuation, .success((body, response))) }
          if let error { return (continuation, .failure(error)) }
          guard let response else {
            return (continuation, .failure(PutioRuntimeError.invalidResponse))
          }
          return (continuation, .success((body, response)))
        }
    continuation?.resume(with: result)
  }
}

@MainActor
@Observable
final class PutioPreviewModel {
  let route: PutioViewerRoute
  private(set) var state: PutioPreviewState
  private let download: PutioPreviewDownload
  private var generation: UInt64 = 0
  private var loadTask: Task<Void, Never>?

  init(route: PutioViewerRoute, download: @escaping PutioPreviewDownload) {
    self.route = route
    self.download = download
    if case .cannotShow = route {
      state = .failed(.cannotShow)
    } else {
      state = .loading
    }
  }

  /// A new load cancels the previous one so at most one body is in flight.
  func load() async {
    loadTask?.cancel()
    generation &+= 1
    let request = generation
    guard case .preview(let route) = route else {
      state = .failed(.cannotShow)
      return
    }
    state = .loading
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let data = try await download(route)
        try Task.checkCancellation()
        let decoded = try await Self.decode(data, kind: route.kind)
        guard request == generation, !Task.isCancelled else { return }
        state = decoded
      } catch {
        guard request == generation, !Task.isCancelled, !(error is CancellationError) else {
          return
        }
        guard let failure = PutioPreviewFailure.resolving(error) else { return }
        state = .failed(failure)
      }
    }
    loadTask = task
    await task.value
  }

  func retry() async {
    await load()
  }

  func cancel() {
    loadTask?.cancel()
    loadTask = nil
    generation &+= 1
  }

  /// The longest edge a decoded preview bitmap may have; ImageIO downsamples
  /// larger originals so the byte cap also bounds decoded memory.
  static let maximumImagePixels = 4096

  /// Images decode on the global concurrent executor through a structured
  /// `@concurrent` call, so the main actor stays free and cancelling the load
  /// cancels the decode. PDFDocument is not Sendable and
  /// PDFKit parses pages lazily on its own threads, so it stays on the main
  /// actor.
  private static func decode(_ data: Data, kind: PutioPreviewRoute.Kind) async throws
    -> PutioPreviewState
  {
    switch kind {
    case .image:
      let image = try await decodeImage(data, maximumPixels: maximumImagePixels)
      guard let image else { return .failed(.cannotShow) }
      return .image(image)
    case .pdf:
      try Task.checkCancellation()
      guard let document = PDFDocument(data: data), document.pageCount > 0 else {
        return .failed(.cannotShow)
      }
      return .document(document)
    case .text:
      let text = try await PutioTextPreview.decode(data, limit: PutioPreviewRoute.textLimitBytes)
      guard let text else { return .failed(.cannotShow) }
      return .text(text)
    }
  }

  @concurrent
  nonisolated static func decodeImage(_ data: Data, maximumPixels: Int) async throws -> UIImage? {
    try Task.checkCancellation()
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
      return nil
    }
    let options =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
      ] as CFDictionary
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
      return nil
    }
    try Task.checkCancellation()
    return UIImage(cgImage: cgImage)
  }
}

struct PutioTextPreview: Equatable, Sendable {
  let text: String
  let isTruncated: Bool

  static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

  @concurrent
  nonisolated static func decode(_ data: Data, limit: Int) async throws -> Self? {
    try Task.checkCancellation()
    let isTruncated = data.count > limit
    var bytes = Array(data.prefix(limit))
    if bytes.starts(with: byteOrderMark) { bytes.removeFirst(byteOrderMark.count) }
    guard !bytes.contains(0) else { return nil }
    let whole = bytes.dropLast(isTruncated ? incompleteScalarLength(at: bytes) : 0)
    if let text = String(validating: whole, as: UTF8.self) {
      return Self(text: text, isTruncated: isTruncated)
    }
    guard let text = String(data: Data(bytes), encoding: .windowsCP1252) else { return nil }
    return Self(text: text, isTruncated: isTruncated)
  }

  nonisolated static func incompleteScalarLength(at bytes: [UInt8]) -> Int {
    var continuations = 0
    for byte in bytes.reversed().prefix(4) {
      guard byte & 0xC0 == 0x80 else {
        let length =
          switch byte {
          case 0xF0...: 4
          case 0xE0...: 3
          case 0xC0...: 2
          default: 1
          }
        return length > continuations + 1 ? continuations + 1 : 0
      }
      continuations += 1
    }
    return 0
  }
}

struct PutioPreviewView: View {
  @State private var model: PutioPreviewModel
  @State private var barsHidden = false
  @State private var documentPage = PutioPDFPagePosition(index: 0, count: 0)
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  private let onDismiss: @MainActor () -> Void

  init(
    route: PutioViewerRoute,
    download: @escaping PutioPreviewDownload,
    onDismiss: @escaping @MainActor () -> Void
  ) {
    _model = State(initialValue: PutioPreviewModel(route: route, download: download))
    self.onDismiss = onDismiss
  }

  var body: some View {
    NavigationStack {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .top) { topFade }
        .overlay(alignment: .bottom) { pagePill }
        .navigationTitle(model.route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbar(showsBars ? .visible : .hidden, for: .navigationBar)
        .statusBarHidden(!showsBars)
    }
    .task { await model.load() }
    .onDisappear { model.cancel() }
    .accessibilityIdentifier("preview.screen.\(model.route.id.rawValue)")
  }

  private var showsImage: Bool {
    if case .image = model.state { true } else { false }
  }

  private var showsDocument: Bool {
    if case .document = model.state { true } else { false }
  }

  private var showsText: Bool {
    if case .text = model.state { true } else { false }
  }

  private var showsBars: Bool {
    !(barsHidden && showsImage && !voiceOverEnabled)
  }

  private func toggleBars() {
    withAnimation(.easeInOut(duration: 0.2)) { barsHidden.toggle() }
  }

  @ViewBuilder
  private var topFade: some View {
    if showsDocument || showsText {
      PutioPDFBarFade()
    } else if showsImage, showsBars {
      LinearGradient(
        colors: [Color.black.opacity(0.6), Color.black.opacity(0)],
        startPoint: .top, endPoint: .bottom
      )
      .frame(height: 120)
      .ignoresSafeArea(edges: .top)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .transition(.opacity)
    }
  }

  @ViewBuilder
  private var pagePill: some View {
    if showsDocument, documentPage.showsPill {
      PutioPDFPagePill(position: documentPage)
    }
  }

  static let textLimitLabel = PutioFileRowModel.sizeText(
    bytes: Int64(PutioPreviewRoute.textLimitBytes))

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button {
        onDismiss()
      } label: {
        Label(String(localized: "Back"), systemImage: "chevron.left")
          .labelStyle(.iconOnly)
      }
      .tint(PutioTheme.Colors.textPrimary)
      .accessibilityIdentifier("preview.back")
    }
    ToolbarItem(placement: .principal) {
      Text(model.route.title)
        .putioFont(PutioTheme.Typography.subheading)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("preview.title")
    }
    ToolbarItemGroup(placement: .topBarTrailing) {
      Button {
      } label: {
        Label {
          Text("Share")
        } icon: {
          Image(putioIcon: .export)
        }
      }
      .disabled(true)
      .accessibilityIdentifier("preview.share")
      Button {
      } label: {
        Label {
          Text("More")
        } icon: {
          Image(putioIcon: .dotsThree)
        }
      }
      .disabled(true)
      .accessibilityIdentifier("preview.more")
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: String(localized: "Loading"), titleVisibility: .hidden)
        .ignoresSafeArea()
        .accessibilityIdentifier("preview.loading")
    case .image(let image):
      PutioZoomableImageView(image: image, title: model.route.title, onSingleTap: toggleBars)
        .ignoresSafeArea()
        .accessibilityIdentifier("preview.image")
    case .document(let document):
      PutioPDFView(document: document) { documentPage = $0 }
        .ignoresSafeArea(edges: .vertical)
        .accessibilityLabel(Text("\(model.route.title), \(document.pageCount) pages"))
        .accessibilityIdentifier("preview.document")
    case .text(let preview):
      PutioTextPreviewView(
        preview: preview,
        truncationNotice: PutioTextPreviewNotice(
          text: String(localized: "Showing the first \(Self.textLimitLabel)."),
          figure: Self.textLimitLabel)
      )
      .ignoresSafeArea(edges: .vertical)
    case .failed(.loadFailed):
      PutioErrorStateView(kind: .failed, retryIdentifier: "preview.retry") {
        Task { await model.retry() }
      }
      .ignoresSafeArea()
    case .failed(.cannotShow):
      PutioEmptyStateView(
        kaomoji: .uneasy,
        title: String(localized: "Can’t show this file here."),
        message: String(localized: "Open it on put.io from a browser instead.")
      )
      .ignoresSafeArea()
      .accessibilityIdentifier("preview.cannot-show")
    }
  }
}

/// UIScrollView zoom keeps the system's pinch, double-tap, and pan feel; SwiftUI
/// gestures cannot match its deceleration and bounds clamping.
struct PutioZoomableImageView: UIViewRepresentable {
  let image: UIImage
  let title: String
  let onSingleTap: @MainActor () -> Void

  func makeUIView(context: Context) -> PutioZoomingScrollView {
    let scrollView = PutioZoomingScrollView(image: image, title: title)
    scrollView.accessibilityLabel = title
    scrollView.onSingleTap = onSingleTap
    return scrollView
  }

  func updateUIView(_ scrollView: PutioZoomingScrollView, context: Context) {
    // SwiftUI re-runs this on unrelated invalidations; only a new image resets zoom.
    scrollView.update(image: image, title: title)
    scrollView.onSingleTap = onSingleTap
  }
}

final class PutioZoomingScrollView: UIScrollView, UIScrollViewDelegate {
  private let imageView = UIImageView()
  private var fittedSize: CGSize = .zero
  var onSingleTap: (@MainActor () -> Void)?

  init(image: UIImage, title: String) {
    super.init(frame: .zero)
    delegate = self
    minimumZoomScale = 1
    maximumZoomScale = 6
    showsVerticalScrollIndicator = false
    showsHorizontalScrollIndicator = false
    backgroundColor = .clear
    contentInsetAdjustmentBehavior = .never
    topEdgeEffect.isHidden = true
    imageView.contentMode = .scaleAspectFit
    imageView.isAccessibilityElement = true
    imageView.accessibilityTraits = .image
    addSubview(imageView)
    update(image: image, title: title)
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
    doubleTap.numberOfTapsRequired = 2
    addGestureRecognizer(doubleTap)
    let singleTap = UITapGestureRecognizer(target: self, action: #selector(toggleBars))
    singleTap.require(toFail: doubleTap)
    addGestureRecognizer(singleTap)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func update(image: UIImage, title: String) {
    imageView.accessibilityLabel = title
    guard imageView.image !== image else { return }
    imageView.image = image
    fittedSize = .zero
    setNeedsLayout()
  }

  /// Fits the image into the bounds at 1x so pinch, pan, and double tap act on
  /// the picture itself; letterboxing lives in the content inset.
  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.size != fittedSize, bounds.width > 0, bounds.height > 0 else {
      center()
      return
    }
    fittedSize = bounds.size
    zoomScale = 1
    let imageSize = imageView.image?.size ?? .zero
    let scale =
      imageSize.width > 0 && imageSize.height > 0
      ? min(bounds.width / imageSize.width, bounds.height / imageSize.height) : 1
    let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    imageView.frame = CGRect(origin: .zero, size: fitted)
    contentSize = fitted
    center()
    contentOffset = restingOffset
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

  func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

  func scrollViewDidEndZooming(
    _ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat
  ) {
    // Back at 1x the picture is smaller than the bounds; any leftover pan
    // offset would park it off-center.
    if scale <= minimumZoomScale {
      center()
      setContentOffset(restingOffset, animated: false)
    }
  }

  @objc private func toggleBars() {
    onSingleTap?()
  }

  /// Zooms 3x into the tapped point of the fitted image. The rect is in the
  /// image view's own coordinates: its unzoomed bounds divided by the target
  /// scale, clamped to the picture so the focal point stays on the image.
  @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
    if zoomScale > minimumZoomScale {
      setZoomScale(minimumZoomScale, animated: true)
      return
    }
    let scale = min(maximumZoomScale, 3)
    let fitted = imageView.bounds.size
    guard fitted.width > 0, fitted.height > 0 else { return }
    let size = CGSize(width: fitted.width / scale, height: fitted.height / scale)
    let point = recognizer.location(in: imageView)
    let origin = CGPoint(
      x: min(max(0, point.x - size.width / 2), fitted.width - size.width),
      y: min(max(0, point.y - size.height / 2), fitted.height - size.height))
    zoom(to: CGRect(origin: origin, size: size), animated: true)
  }

  private var restingOffset: CGPoint {
    CGPoint(x: -contentInset.left, y: -contentInset.top)
  }

  private func center() {
    let horizontal = max(0, (bounds.width - imageView.frame.width) / 2)
    let vertical = max(0, (bounds.height - imageView.frame.height) / 2)
    contentInset = UIEdgeInsets(
      top: vertical, left: horizontal, bottom: vertical, right: horizontal)
  }
}

struct PutioTextPreviewView: UIViewRepresentable {
  let preview: PutioTextPreview
  let truncationNotice: PutioTextPreviewNotice

  func makeUIView(context: Context) -> PutioTextPreviewContainer {
    PutioTextPreviewContainer()
  }

  func updateUIView(_ view: PutioTextPreviewContainer, context: Context) {
    view.show(preview, truncationNotice: truncationNotice)
  }
}

struct PutioTextPreviewNotice: Equatable {
  let text: String
  let figure: String

  func attributed(font: UIFont, figureFont: UIFont, color: UIColor) -> NSAttributedString {
    let attributed = NSMutableAttributedString(
      string: text, attributes: [.font: font, .foregroundColor: color])
    if let range = text.range(of: figure) {
      attributed.addAttribute(.font, value: figureFont, range: NSRange(range, in: text))
    }
    return attributed
  }
}

final class PutioTextPreviewContainer: UIView, UITextViewDelegate {
  private let textView = UITextView(usingTextLayoutManager: true)
  private let notice = UILabel()
  private lazy var textElement = PutioVisibleTextElement(container: self, textView: textView)
  private var shown: PutioTextPreview?
  private var shownNotice: PutioTextPreviewNotice?

  private static let inset = PutioTheme.Spacing.space3
  private static let noticeSpacing = PutioTheme.Spacing.space3 + PutioTheme.Spacing.space2
  private static let noticeInset = PutioTheme.Spacing.space4

  init() {
    super.init(frame: .zero)
    clipsToBounds = true
    textView.delegate = self
    textView.isEditable = false
    textView.isSelectable = true
    textView.backgroundColor = .clear
    textView.alwaysBounceVertical = true
    textView.contentInsetAdjustmentBehavior = .always
    textView.topEdgeEffect.isHidden = true
    textView.textContainer.lineFragmentPadding = 0
    addSubview(textView)
    notice.numberOfLines = 0
    notice.accessibilityIdentifier = "preview.text.truncated"
    notice.isHidden = true
    addSubview(notice)
    registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
      (view: PutioTextPreviewContainer, _) in
      view.restyle()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func show(_ preview: PutioTextPreview, truncationNotice: PutioTextPreviewNotice) {
    notice.isHidden = !preview.isTruncated
    accessibilityElements = preview.isTruncated ? [textElement, notice] : [textElement]
    guard preview != shown || truncationNotice != shownNotice else { return }
    shown = preview
    shownNotice = truncationNotice
    restyle()
  }

  private func restyle() {
    guard let shown else { return }
    let mono = PutioTheme.Typography.mono.scaledUIFont(
      compatibleWith: traitCollection, fallback: UIFont.monospacedSystemFont(ofSize:weight:))
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = mono.lineHeight
    paragraph.maximumLineHeight = mono.lineHeight
    textView.attributedText = NSAttributedString(
      string: shown.text,
      attributes: [
        .font: mono.font, .paragraphStyle: paragraph,
        .foregroundColor: UIColor(PutioTheme.Colors.textPrimary),
      ])
    if let shownNotice {
      notice.attributedText = shownNotice.attributed(
        font: PutioTheme.Typography.caption.scaledUIFont(
          compatibleWith: traitCollection, fallback: UIFont.systemFont(ofSize:weight:)
        ).font,
        figureFont: mono.font,
        color: UIColor(PutioTheme.Colors.textSecondary))
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    textView.frame = bounds
    let width = max(0, bounds.width - 2 * Self.noticeInset)
    let noticeHeight =
      notice.isHidden
      ? 0 : notice.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    let bottom =
      notice.isHidden ? Self.noticeInset : Self.noticeSpacing + noticeHeight + Self.noticeInset
    let insets = UIEdgeInsets(
      top: Self.inset, left: Self.inset, bottom: bottom, right: Self.inset)
    if textView.textContainerInset != insets { textView.textContainerInset = insets }
    notice.frame.size = CGSize(width: width, height: noticeHeight)
    placeNotice()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    placeNotice()
  }

  private func placeNotice() {
    guard !notice.isHidden else { return }
    let textEnd = textView.contentSize.height - textView.textContainerInset.bottom
    notice.frame.origin = CGPoint(
      x: Self.noticeInset,
      y: textEnd + Self.noticeSpacing - textView.contentOffset.y)
  }
}

final class PutioVisibleTextElement: UIAccessibilityElement {
  private weak var textView: UITextView?

  init(container: UIView, textView: UITextView) {
    self.textView = textView
    super.init(accessibilityContainer: container)
    accessibilityIdentifier = "preview.text"
    accessibilityTraits = .staticText
    accessibilityCustomActions = [
      UIAccessibilityCustomAction(name: String(localized: "Copy all")) { [weak textView] _ in
        guard let text = textView?.text else { return false }
        UIPasteboard.general.string = text
        return true
      }
    ]
  }

  override var accessibilityFrameInContainerSpace: CGRect {
    get { textView?.frame ?? .zero }
    set {}
  }

  override var accessibilityValue: String? {
    get { textView.flatMap(Self.visibleText(in:)) }
    set {}
  }

  override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
    guard let textView else { return false }
    let inset = textView.adjustedContentInset
    let page = textView.bounds.height - inset.top - inset.bottom
    let minY = -inset.top
    let maxY = max(minY, textView.contentSize.height + inset.bottom - textView.bounds.height)
    let y: CGFloat
    switch direction {
    case .down: y = min(maxY, textView.contentOffset.y + page)
    case .up: y = max(minY, textView.contentOffset.y - page)
    default: return false
    }
    guard y != textView.contentOffset.y else { return false }
    textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: y), animated: false)
    UIAccessibility.post(notification: .pageScrolled, argument: accessibilityValue)
    return true
  }

  private static func visibleText(in textView: UITextView) -> String? {
    let visible = textView.bounds.inset(by: textView.adjustedContentInset)
    guard let start = textView.closestPosition(to: CGPoint(x: visible.minX, y: visible.minY)),
      let end = textView.closestPosition(to: CGPoint(x: visible.maxX, y: visible.maxY)),
      let range = textView.textRange(from: start, to: end)
    else { return nil }
    return textView.text(in: range)
  }
}

extension PutioFontRole {
  struct ScaledUIFont {
    let font: UIFont
    let lineHeight: CGFloat
  }

  func scaledUIFont(
    compatibleWith traits: UITraitCollection,
    fallback: (CGFloat, UIFont.Weight) -> UIFont
  ) -> ScaledUIFont {
    let metrics = UIFontMetrics(forTextStyle: textStyle.uiTextStyle)
    let base = UIFont(name: fontName, size: size) ?? fallback(size, .regular)
    return ScaledUIFont(
      font: metrics.scaledFont(for: base, compatibleWith: traits),
      lineHeight: metrics.scaledValue(for: size * lineHeight, compatibleWith: traits))
  }
}

extension Font.TextStyle {
  fileprivate var uiTextStyle: UIFont.TextStyle {
    switch self {
    case .largeTitle: .largeTitle
    case .title: .title1
    case .title2: .title2
    case .title3: .title3
    case .headline: .headline
    case .subheadline: .subheadline
    case .callout: .callout
    case .footnote: .footnote
    case .caption: .caption1
    case .caption2: .caption2
    default: .body
    }
  }
}

struct PutioPDFPagePosition: Equatable {
  let index: Int
  let count: Int

  var showsPill: Bool { count > 1 }
  var number: Int { index + 1 }
}

struct PutioPDFBarFade: View {
  static func stops(barBottom: CGFloat) -> [Gradient.Stop] {
    guard barBottom > 0 else { return [] }
    let solid = max(0, barBottom - PutioTheme.Spacing.space3) / barBottom
    return [
      .init(color: .black, location: 0), .init(color: .black, location: solid),
      .init(color: .black.opacity(0), location: 1),
    ]
  }

  var body: some View {
    GeometryReader { proxy in
      let insets = proxy.safeAreaInsets
      LinearGradient(
        stops: Self.stops(barBottom: insets.top), startPoint: .top, endPoint: .bottom
      )
      .frame(width: proxy.size.width + insets.leading + insets.trailing, height: insets.top)
      .offset(x: -insets.leading, y: -insets.top)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct PutioPDFPagePill: View {
  let position: PutioPDFPagePosition

  var body: some View {
    Text("\(position.number) of \(position.count)")
      .putioFont(PutioTheme.Typography.numeric)
      .foregroundStyle(PutioTheme.Colors.textPrimary)
      .padding(.horizontal, PutioTheme.Spacing.space3)
      .padding(.vertical, PutioTheme.Spacing.space1)
      .background(PutioTheme.Colors.surfaceActive, in: Capsule())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text("Page \(position.number) of \(position.count)"))
      .accessibilityIdentifier("preview.page")
      .allowsHitTesting(false)
  }
}

struct PutioPDFView: UIViewRepresentable {
  let document: PDFDocument
  let onPageChange: @MainActor (PutioPDFPagePosition) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.displaysPageBreaks = true
    view.pageShadowsEnabled = false
    view.pageBreakMargins = UIEdgeInsets(
      top: PutioTheme.Spacing.space1, left: 0, bottom: PutioTheme.Spacing.space1, right: 0)
    view.backgroundColor = .black
    view.document = document
    view.firstScrollView?.topEdgeEffect.isHidden = true
    context.coordinator.observe(view, onPageChange: onPageChange)
    return view
  }

  func updateUIView(_ view: PDFView, context: Context) {
    if view.document !== document { view.document = document }
    context.coordinator.observe(view, onPageChange: onPageChange)
  }

  static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator {
    private var observer: NSObjectProtocol?
    private var onPageChange: (@MainActor (PutioPDFPagePosition) -> Void)?
    private var reported: PutioPDFPagePosition?

    func observe(
      _ view: PDFView, onPageChange: @escaping @MainActor (PutioPDFPagePosition) -> Void
    ) {
      self.onPageChange = onPageChange
      if observer == nil {
        observer = NotificationCenter.default.addObserver(
          forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [weak self, weak view] _ in
          MainActor.assumeIsolated {
            guard let self, let view else { return }
            self.report(view)
          }
        }
      }
      Task { @MainActor [weak self, weak view] in
        guard let self, let view else { return }
        self.report(view)
      }
    }

    func stop() {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
    }

    private func report(_ view: PDFView) {
      guard let document = view.document else { return }
      let index = view.currentPage.map { document.index(for: $0) } ?? 0
      let position = PutioPDFPagePosition(index: index, count: document.pageCount)
      guard position != reported else { return }
      reported = position
      onPageChange?(position)
    }
  }
}

extension UIView {
  fileprivate var firstScrollView: UIScrollView? {
    for subview in subviews {
      if let scrollView = subview as? UIScrollView { return scrollView }
      if let nested = subview.firstScrollView { return nested }
    }
    return nil
  }
}
