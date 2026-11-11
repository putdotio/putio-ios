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
  case failed(PutioPreviewFailure)

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.loading, .loading): true
    case (.image(let left), .image(let right)): left === right
    case (.document(let left), .document(let right)): left === right
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

typealias PutioPreviewDownload = @MainActor @Sendable (PutioFileID) async throws -> Data

struct PutioPreviewTooLargeError: Error {}

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
    let collector = PutioBoundedBodyCollector(limit: limit)
    let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (data, http) = try await collector.run(session.dataTask(with: url))
    switch http.statusCode {
    case 200...299: return data
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
  private let lock = NSLock()
  private var body = Data()
  private var response: HTTPURLResponse?
  private var tooLarge = false
  private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

  init(limit: Int) {
    self.limit = limit
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
    let oversized = http.expectedContentLength > Int64(limit)
    lock.withLock {
      self.response = http
      if oversized { tooLarge = true }
    }
    completionHandler(oversized ? .cancel : .allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let exceeded = lock.withLock {
      // Nothing past the cap is ever buffered, including the chunk that trips it.
      guard !tooLarge else { return true }
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
        let data = try await download(route.id)
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

  private static let imageFade: [Gradient.Stop] = [
    .init(color: .black.opacity(0.6), location: 0), .init(color: .black.opacity(0), location: 1),
  ]

  private static let documentFade: [Gradient.Stop] = [
    .init(color: .black, location: 0), .init(color: .black.opacity(0.85), location: 0.45),
    .init(color: .black.opacity(0), location: 1),
  ]

  private var showsDocument: Bool {
    if case .document = model.state { true } else { false }
  }

  private var showsBars: Bool {
    !(barsHidden && showsImage && !voiceOverEnabled)
  }

  private func toggleBars() {
    withAnimation(.easeInOut(duration: 0.2)) { barsHidden.toggle() }
  }

  @ViewBuilder
  private var topFade: some View {
    if showsImage && showsBars || showsDocument {
      LinearGradient(
        stops: showsDocument ? Self.documentFade : Self.imageFade,
        startPoint: .top, endPoint: .bottom
      )
      .frame(height: showsDocument ? 150 : 120)
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
        .ignoresSafeArea()
        .accessibilityLabel(Text("\(model.route.title), \(document.pageCount) pages"))
        .accessibilityIdentifier("preview.document")
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

struct PutioPDFPagePosition: Equatable {
  let index: Int
  let count: Int

  var showsPill: Bool { count > 1 }
  var number: Int { index + 1 }
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
