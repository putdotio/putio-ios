import ImageIO
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

struct PutioPreviewFailure: Equatable {
  enum Kind: Equatable {
    case notFound
    case rateLimited
    case transient
    case invalidResponse
    case unreadable
    case tooLarge
    case unknown
  }

  let kind: Kind
  let title: String
  let message: String

  static func resolving(_ error: Error, kind previewKind: PutioPreviewRoute.Kind) -> Self? {
    let noun = previewKind == .image ? "image" : "document"
    if error is PutioPreviewTooLargeError {
      return Self(
        kind: .tooLarge, title: "\(noun.capitalized) too large to preview",
        message: "Open it on put.io from a browser instead.")
    }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired:
      return nil
    case .notFound:
      return Self(
        kind: .notFound, title: "\(noun.capitalized) not found",
        message: "It may have been moved or deleted.")
    case .rateLimited:
      return Self(
        kind: .rateLimited, title: "Could not open \(noun)",
        message: "put.io is receiving too many requests. Try again shortly.")
    case .transient:
      return Self(
        kind: .transient, title: "Could not open \(noun)",
        message: "Check your connection and try again.")
    case .invalidResponse:
      return Self(
        kind: .invalidResponse, title: "Could not open \(noun)",
        message: "put.io returned an invalid response. Try again.")
    case .unknown, nil:
      if let urlError = error as? URLError, urlError.code != .cancelled {
        return Self(
          kind: .transient, title: "Could not open \(noun)",
          message: "Check your connection and try again.")
      }
      return Self(
        kind: .unknown, title: "Could not open \(noun)",
        message: "put.io could not prepare this \(noun). Try again.")
    }
  }

  static func unreadable(kind previewKind: PutioPreviewRoute.Kind) -> Self {
    let noun = previewKind == .image ? "image" : "document"
    return Self(
      kind: .unreadable, title: "Could not display \(noun)",
      message: "The \(noun) could not be read. Try again.")
  }
}

typealias PutioPreviewDownload = @MainActor @Sendable (PutioFileID) async throws -> Data

struct PutioPreviewTooLargeError: Error {}

/// Downloads a preview body with a hard byte cap so a large original cannot
/// exhaust memory. The response is inspected before any body arrives and the
/// task is cancelled the moment the cap is crossed. Larger files stay on
/// put.io. 401/403 surface as session loss so the signed-out shell takes over.
enum PutioPreviewDownloader {
  static let maximumBytes = 64 * 1024 * 1024

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
      // Chunks that land after the cap trips are dropped, not buffered.
      guard !tooLarge else { return true }
      body.append(data)
      if body.count > limit { tooLarge = true }
      return tooLarge
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
  let route: PutioPreviewRoute
  private(set) var state: PutioPreviewState = .loading
  private let download: PutioPreviewDownload
  private var generation: UInt64 = 0
  private var loadTask: Task<Void, Never>?

  init(route: PutioPreviewRoute, download: @escaping PutioPreviewDownload) {
    self.route = route
    self.download = download
  }

  /// A new load cancels the previous one so at most one body is in flight.
  func load() async {
    loadTask?.cancel()
    generation &+= 1
    let request = generation
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
        guard let failure = PutioPreviewFailure.resolving(error, kind: route.kind) else { return }
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
      guard let image else { return .failed(.unreadable(kind: kind)) }
      return .image(image)
    case .pdf:
      try Task.checkCancellation()
      guard let document = PDFDocument(data: data), document.pageCount > 0 else {
        return .failed(.unreadable(kind: kind))
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
  private let onDismiss: @MainActor () -> Void

  init(
    route: PutioPreviewRoute,
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
        .putioContentBackground()
        .navigationTitle(model.route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { onDismiss() }
              .accessibilityIdentifier("preview.done")
          }
        }
    }
    .task { await model.load() }
    .onDisappear { model.cancel() }
    .accessibilityIdentifier("preview.screen.\(model.route.id.rawValue)")
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(
        title: model.route.kind == .image ? "Loading image" : "Loading document"
      )
      .accessibilityIdentifier("preview.loading")
    case .image(let image):
      PutioZoomableImageView(image: image, title: model.route.title)
        .accessibilityIdentifier("preview.image")
    case .document(let document):
      PutioPDFView(document: document)
        .accessibilityLabel(Text("\(model.route.title), \(document.pageCount) pages"))
        .accessibilityIdentifier("preview.document")
    case .failed(let failure):
      PutioErrorStateView(
        title: failure.title, message: failure.message, retryTitle: "Try again",
        retryIdentifier: "preview.retry"
      ) {
        Task { await model.retry() }
      }
    }
  }
}

/// UIScrollView zoom keeps the system's pinch, double-tap, and pan feel; SwiftUI
/// gestures cannot match its deceleration and bounds clamping.
struct PutioZoomableImageView: UIViewRepresentable {
  let image: UIImage
  let title: String

  func makeUIView(context: Context) -> PutioZoomingScrollView {
    let scrollView = PutioZoomingScrollView(image: image, title: title)
    scrollView.accessibilityLabel = title
    return scrollView
  }

  func updateUIView(_ scrollView: PutioZoomingScrollView, context: Context) {
    // SwiftUI re-runs this on unrelated invalidations; only a new image resets zoom.
    scrollView.update(image: image, title: title)
  }
}

final class PutioZoomingScrollView: UIScrollView, UIScrollViewDelegate {
  private let imageView = UIImageView()
  private var fittedSize: CGSize = .zero

  init(image: UIImage, title: String) {
    super.init(frame: .zero)
    delegate = self
    minimumZoomScale = 1
    maximumZoomScale = 6
    showsVerticalScrollIndicator = false
    showsHorizontalScrollIndicator = false
    backgroundColor = .clear
    contentInsetAdjustmentBehavior = .never
    imageView.contentMode = .scaleAspectFit
    imageView.isAccessibilityElement = true
    imageView.accessibilityTraits = .image
    addSubview(imageView)
    update(image: image, title: title)
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
    doubleTap.numberOfTapsRequired = 2
    addGestureRecognizer(doubleTap)
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
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

  func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

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

  private func center() {
    let horizontal = max(0, (bounds.width - imageView.frame.width) / 2)
    let vertical = max(0, (bounds.height - imageView.frame.height) / 2)
    contentInset = UIEdgeInsets(
      top: vertical, left: horizontal, bottom: vertical, right: horizontal)
  }
}

struct PutioPDFView: UIViewRepresentable {
  let document: PDFDocument

  func makeUIView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.backgroundColor = UIColor(PutioTheme.Colors.background)
    view.document = document
    return view
  }

  func updateUIView(_ view: PDFView, context: Context) {
    if view.document !== document { view.document = document }
  }
}

/// A file the app cannot render. The sheet names the type and offers the
/// actions that exist for it; there is no spinner and no dead end.
struct PutioUnsupportedFileView: View {
  let route: PutioUnsupportedFileRoute
  let onDismiss: @MainActor () -> Void

  var body: some View {
    NavigationStack {
      PutioEmptyStateView(
        icon: .file,
        title: "Cannot open this file",
        message: message
      )
      .accessibilityIdentifier("unsupported.screen.\(route.id.rawValue)")
      .putioContentBackground()
      .navigationTitle(route.item.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { onDismiss() }
            .accessibilityIdentifier("unsupported.done")
        }
      }
    }
  }

  private var message: String {
    let subject =
      PutioUnsupportedFileView.typeName(for: route.item.kind).map { "\($0) files" }
      ?? "this type of file"
    return
      "put.io for iOS can’t display \(subject) yet. You can move, rename, or delete it from Files, or open it on put.io from a browser."
  }

  /// `nil` when the server sent no usable type name.
  static func typeName(for kind: PutioFileKind) -> String? {
    switch kind {
    case .other(let raw):
      let normalized = raw.replacingOccurrences(of: "_", with: " ").lowercased()
        .trimmingCharacters(in: .whitespaces)
      return normalized.isEmpty ? nil : normalized
    case .folder: return "folder"
    case .video: return "video"
    case .audio: return "audio"
    case .image: return "image"
    case .pdf: return "PDF"
    }
  }
}
