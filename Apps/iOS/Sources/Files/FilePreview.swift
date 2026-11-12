import ImageIO
import Observation
import PDFKit
import PutioCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

  var holdsWholeFile: Bool {
    switch self {
    case .image, .document: true
    case .text(let text): !text.isTruncated
    case .loading, .failed: false
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
    case .preview(let route) where route.exceedsSizeCap && route.kind != .text:
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

enum PutioPreviewExtent: Sendable {
  case preview
  case whole
}

typealias PutioPreviewDownload =
  @MainActor @Sendable (PutioPreviewRoute, PutioPreviewExtent) async throws -> Data

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
  private(set) var title: String
  private(set) var state: PutioPreviewState
  private let download: PutioPreviewDownload
  let shareDirectory: URL
  private var generation: UInt64 = 0
  private var shareGeneration: UInt64 = 0
  private var loadTask: Task<Void, Never>?
  private var loadedBytes: Data?
  private var sharedFile: URL?
  private var shareExport: Task<URL, any Error>?

  init(route: PutioViewerRoute, download: @escaping PutioPreviewDownload) {
    self.route = route
    title = route.title
    self.download = download
    shareDirectory = URL.temporaryDirectory
      .appending(path: "PreviewShare", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
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
    loadedBytes = nil
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let data = try await download(route, .preview)
        try Task.checkCancellation()
        let decoded = try await Self.decode(data, kind: route.kind)
        guard request == generation, !Task.isCancelled else { return }
        loadedBytes = decoded.holdsWholeFile ? data : nil
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

  func loadIfNeeded() async {
    guard case .preview = route, loadTask == nil else { return }
    await load()
  }

  func retry() async {
    await load()
  }

  func cancel() {
    loadTask?.cancel()
    loadTask = nil
    generation &+= 1
    loadedBytes = nil
    discardShareFile()
    try? FileManager.default.removeItem(at: shareDirectory)
  }

  func retitle(_ name: String) {
    guard name != title else { return }
    title = name
    discardShareFile()
  }

  private func discardShareFile() {
    shareGeneration &+= 1
    shareExport?.cancel()
    shareExport = nil
    sharedFile = nil
  }

  var share: PutioPreviewShareFile? {
    guard case .preview(let route) = route else { return nil }
    switch state {
    case .image, .document: break
    case .text(let text) where !text.isTruncated || !route.exceedsSizeCap: break
    case .loading, .text, .failed: return nil
    }
    return PutioPreviewShareFile(name: title, kind: route.kind) { [weak self] in
      guard let self else { throw CancellationError() }
      return try await exportShareFile()
    }
  }

  func exportShareFile() async throws -> URL {
    if let sharedFile { return sharedFile }
    if let shareExport { return try await shareExport.value }
    let request = shareGeneration
    let export = Task { [weak self] in
      guard let self else { throw CancellationError() }
      defer { if request == shareGeneration { shareExport = nil } }
      return try await writeShareFile(request: request)
    }
    shareExport = export
    return try await export.value
  }

  private func writeShareFile(request: UInt64) async throws -> URL {
    guard case .preview(let route) = route else { throw PutioPreviewTooLargeError() }
    let bytes: Data
    if let loadedBytes {
      bytes = loadedBytes
    } else {
      bytes = try await download(route, .whole)
    }
    try Task.checkCancellation()
    let file = shareDirectory.appending(path: Self.shareFileName(title))
    try await Self.write(bytes, to: file)
    guard request == shareGeneration else {
      try? FileManager.default.removeItem(at: file)
      let left = try? FileManager.default.contentsOfDirectory(atPath: shareDirectory.path)
      if left?.isEmpty == true { try? FileManager.default.removeItem(at: shareDirectory) }
      throw CancellationError()
    }
    sharedFile = file
    return file
  }

  static func shareFileName(_ title: String) -> String {
    let name = title.replacing("/", with: ":")
    return name.isEmpty || name == "." || name == ".." ? "file" : name
  }

  @concurrent
  nonisolated private static func write(_ data: Data, to file: URL) async throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
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

struct PutioPreviewOpenAction {
  let open: @MainActor (PutioFileRoute, PutioPreviewSource) -> Void

  @MainActor
  func callAsFunction(_ route: PutioFileRoute, in source: PutioPreviewSource) {
    open(route, source)
  }
}

extension EnvironmentValues {
  @Entry var putioPreviewOpen: PutioPreviewOpenAction? = nil
}

@MainActor
@Observable
final class PutioPreviewPager {
  private let kind: PutioPreviewRoute.Kind?
  private let source: PutioPreviewSource?
  private let opened: PutioFileItem?
  private var lookedUp: [PutioFileID: PutioFileItem] = [:]
  private var unsettled: Set<PutioFileID> = []
  private var removed: Set<PutioFileID> = []
  private var returning: PutioFileID?
  private var shown: [PutioFileID: PutioFileItem] = [:]
  private let download: PutioPreviewDownload
  private(set) var current: PutioViewerRoute
  private(set) var reads = PutioPreviewPageReads()
  @ObservationIgnored private var models: [PutioFileID: PutioPreviewModel] = [:]
  @ObservationIgnored private var pageReader: Task<Void, Never>?

  init(
    opened route: PutioViewerRoute,
    file: PutioFileRoute?,
    source: PutioPreviewSource?,
    download: @escaping PutioPreviewDownload
  ) {
    current = route
    kind = file?.previewKind
    opened = file?.item
    self.source = file?.previewKind == nil ? nil : source
    self.download = download
  }

  var folderSet: PutioPreviewSet? {
    guard let source, let kind else { return nil }
    return PutioPreviewSet(
      items: source.items().filter { !removed.contains($0.id) }, shownID: current.id, kind: kind)
  }

  var routes: [PutioViewerRoute] {
    guard let set = folderSet, set.pages else { return [current] }
    return set.items.compactMap { PutioViewerRoute(opening: PutioFileRoute(item: $0).openAction) }
  }

  var position: PutioPreviewPosition? {
    folderSet?.position(hasMore: (source?.hasMore() ?? false) && !reads.stopped)
  }

  var pagingKey: PutioPreviewPagingKey {
    PutioPreviewPagingKey(
      shown: current.id, loaded: source?.items().count ?? 0, hasMore: source?.hasMore() ?? false)
  }

  var currentModel: PutioPreviewModel { model(for: current) }

  func model(for route: PutioViewerRoute) -> PutioPreviewModel {
    if let model = models[route.id] { return model }
    let model = PutioPreviewModel(route: route, download: download)
    if let name = name(for: route.id) { model.retitle(name) }
    models[route.id] = model
    return model
  }

  func item(for id: PutioFileID) -> PutioFileItem? {
    if let item = lookedUp[id] ?? listed(id) ?? shown[id] { return item }
    guard !unsettled.contains(id), opened?.id == id else { return nil }
    return opened
  }

  func name(for id: PutioFileID) -> String? {
    (lookedUp[id] ?? listed(id))?.name
  }

  func settle(_ id: PutioFileID) {
    lookedUp[id] = nil
    unsettled.insert(id)
  }

  func update(_ item: PutioFileItem) {
    lookedUp[item.id] = item
    unsettled.remove(item.id)
    models[item.id]?.retitle(item.name)
  }

  private func listed(_ id: PutioFileID) -> PutioFileItem? {
    source?.items().first { $0.id == id }
  }

  func remove(_ id: PutioFileID) -> Bool {
    for item in folderSet?.items ?? [] where item.id != id { shown[item.id] = item }
    let routes = routes
    let rest = routes.filter { $0.id != id }
    removed.insert(id)
    if returning == id { returning = nil }
    guard id == current.id else { return true }
    guard !rest.isEmpty, let index = routes.firstIndex(where: { $0.id == id }) else {
      return false
    }
    current = rest[min(index, rest.count - 1)]
    models.removeValue(forKey: id)?.cancel()
    return true
  }

  func reinstate(_ id: PutioFileID) {
    removed.remove(id)
    returning = id
    showReturning()
  }

  func showReturning() {
    guard let id = returning, routes.contains(where: { $0.id == id }) else { return }
    returning = nil
    show(id)
  }

  func show(_ id: PutioFileID) {
    let routes = routes
    guard id != current.id, let index = routes.firstIndex(where: { $0.id == id }) else { return }
    current = routes[index]
    let kept = Set(routes[max(0, index - 1)...min(routes.count - 1, index + 1)].map(\.id))
    for (id, model) in models where !kept.contains(id) {
      model.cancel()
      models[id] = nil
    }
  }

  func readPagesIfNeeded() {
    guard let source, pageReader == nil else { return }
    pageReader = Task { [weak self] in
      await self?.readPages(from: source)
      self?.pageReader = nil
    }
  }

  private func readPages(from source: PutioPreviewSource) async {
    while !Task.isCancelled, needsPage(from: source) {
      let before = kindCount(in: source)
      guard await source.loadMore() else {
        guard let delay = reads.didFail() else { return }
        do { try await Task.sleep(for: delay) } catch { return }
        continue
      }
      reads.didRead(countBefore: before, countAfter: kindCount(in: source))
    }
  }

  private func needsPage(from source: PutioPreviewSource) -> Bool {
    guard let set = folderSet else { return source.hasMore() && !reads.stopped }
    return reads.shouldRead(index: set.index, count: set.items.count, hasMore: source.hasMore())
  }

  private func kindCount(in source: PutioPreviewSource) -> Int {
    source.items().count {
      !removed.contains($0.id) && PutioFileRoute(item: $0).previewKind == kind
    }
  }

  func cancel() {
    pageReader?.cancel()
    for model in models.values { model.cancel() }
  }
}

struct PutioPreviewLookup: Equatable {
  let fileID: PutioFileID
  let id = UUID()
}

struct PutioPreviewPresentation: Identifiable {
  let route: PutioViewerRoute
  let file: PutioFileRoute
  let source: PutioPreviewSource?

  var id: PutioFileID { route.id }
}

struct PutioPreviewPagingKey: Hashable {
  let shown: PutioFileID
  let loaded: Int
  let hasMore: Bool
}

struct PutioPreviewShareFile: Transferable {
  let name: String
  let kind: PutioPreviewRoute.Kind
  let export: @Sendable () async throws -> URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .png) { try await $0.sent() }
      .exportingCondition { $0.imageType == .png }
      .suggestedFileName { $0.name }
    FileRepresentation(exportedContentType: .jpeg) { try await $0.sent() }
      .exportingCondition { $0.imageType == .jpeg }
      .suggestedFileName { $0.name }
    FileRepresentation(exportedContentType: .heic) { try await $0.sent() }
      .exportingCondition { $0.imageType == .heic }
      .suggestedFileName { $0.name }
    FileRepresentation(exportedContentType: .gif) { try await $0.sent() }
      .exportingCondition { $0.imageType == .gif }
      .suggestedFileName { $0.name }
    FileRepresentation(exportedContentType: .webP) { try await $0.sent() }
      .exportingCondition { $0.imageType == .webP }
      .suggestedFileName { $0.name }
    FileRepresentation(exportedContentType: .image) { try await $0.sent() }
      .exportingCondition { $0.kind == .image && $0.imageType == nil }
      .suggestedFileName { $0.name }
    FileRepresentation(exportedContentType: .pdf) { try await $0.sent() }
      .exportingCondition { $0.kind == .pdf }
      .suggestedFileName { $0.name }
    FileRepresentation(exportedContentType: .plainText) { try await $0.sent() }
      .exportingCondition { $0.kind == .text }
      .suggestedFileName { $0.name }
  }

  static let concreteImageTypes: [UTType] = [.png, .jpeg, .heic, .gif, .webP]

  var imageType: UTType? {
    guard kind == .image else { return nil }
    let named = UTType(filenameExtension: (name as NSString).pathExtension)
    return Self.concreteImageTypes.first { named?.conforms(to: $0) == true }
  }

  private func sent() async throws -> SentTransferredFile {
    SentTransferredFile(try await export(), allowAccessingOriginalFile: false)
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
  @State private var pager: PutioPreviewPager
  @State private var position = ScrollPosition()
  @State private var alignedWidth: CGFloat = 0
  @State private var barsHidden = false
  @State private var documentPages: [PutioFileID: PutioPDFPagePosition] = [:]
  @State private var zoomedID: PutioFileID?
  @State private var itemActions: PutioFileItemActionModel
  @State private var itemAction: PutioFileItemActionRequest?
  @State private var actedOn: PutioFileID?
  @State private var lookup: PutioPreviewLookup?
  @State private var toast: PutioToast?
  @State private var confirmAlert: PutioConfirmAlert?
  @State private var labelsHeight: CGFloat = 0
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  private let fileActions: PutioPreviewFileActions
  private let onDismiss: @MainActor () -> Void
  private let presentToast: @MainActor (PutioToast) -> Void

  init(
    route: PutioViewerRoute,
    file: PutioFileRoute? = nil,
    source: PutioPreviewSource? = nil,
    fileActions: PutioPreviewFileActions,
    download: @escaping PutioPreviewDownload,
    onDismiss: @escaping @MainActor () -> Void,
    presentToast: @escaping @MainActor (PutioToast) -> Void
  ) {
    _pager = State(
      initialValue: PutioPreviewPager(
        opened: route, file: file, source: source, download: download))
    _itemActions = State(
      initialValue: PutioFileItemActionModel(
        actions: fileActions.actions, refreshRequests: fileActions.refreshRequests))
    self.fileActions = fileActions
    self.onDismiss = onDismiss
    self.presentToast = presentToast
  }

  var body: some View {
    let model = pager.currentModel
    NavigationStack {
      pages
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .top) { topFade(model.state) }
        .overlay(alignment: .bottom) {
          bottomLabels(model.state)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { labelsHeight = $0 }
        }
        .overlay {
          Color.clear
            .putioToast($toast)
            .padding(.bottom, labelsHeight)
        }
        .putioConfirmAlert($confirmAlert)
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(model) }
        .toolbar(showsBars(model.state) ? .visible : .hidden, for: .navigationBar)
        .statusBarHidden(!showsBars(model.state))
        .modifier(
          PutioFileItemActionsHost(
            request: $itemAction,
            model: itemActions,
            actions: fileActions.actions,
            load: fileActions.load,
            continueLoad: fileActions.continueLoad,
            trashEnabled: fileActions.trashEnabled,
            refreshRequests: fileActions.refreshRequests
          )
        )
    }
    .onChange(of: pager.name(for: pager.current.id)) { _, name in
      if let name { pager.currentModel.retitle(name) }
    }
    .onChange(of: itemActions.canStartAction) { _, idle in
      guard idle, let id = actedOn else { return }
      pager.settle(id)
      lookup = PutioPreviewLookup(fileID: id)
    }
    .task(id: lookup) { await lookUpSettledFile() }
    .onChange(of: pager.pagingKey, initial: true) {
      pager.showReturning()
      pager.readPagesIfNeeded()
    }
    .onDisappear { pager.cancel() }
    .accessibilityIdentifier("preview.screen.\(model.route.id.rawValue)")
  }

  private var pages: some View {
    let routes = pager.routes
    let current = pager.current.id
    return GeometryReader { proxy in
      pageScroller(routes: routes, current: current, insets: proxy.safeAreaInsets)
        .ignoresSafeArea()
    }
  }

  private func pageScroller(
    routes: [PutioViewerRoute], current: PutioFileID, insets: EdgeInsets
  ) -> some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: 0) {
        ForEach(routes) { route in
          PutioPreviewPage(
            model: pager.model(for: route),
            isCurrent: route.id == current,
            insets: insets,
            onSingleTap: toggleBars,
            onZoomChange: { zoomed in
              if zoomed {
                zoomedID = route.id
              } else if zoomedID == route.id {
                zoomedID = nil
              }
            },
            onDocumentPage: { documentPages[route.id] = $0 }
          )
          .containerRelativeFrame([.horizontal, .vertical])
        }
      }
      .scrollTargetLayout()
    }
    .scrollTargetBehavior(.paging)
    .scrollPosition($position)
    .scrollIndicators(.hidden)
    .scrollEdgeEffectHidden(true, for: .all)
    .scrollDisabled(routes.count < 2 || zoomedID == current)
    .onScrollGeometryChange(for: CGFloat.self, of: \.containerSize.width) { _, width in
      align(width: width)
    }
    .onScrollPhaseChange { _, phase, context in
      guard phase == .idle, alignedWidth > 0, let index = Self.pageIndex(context.geometry),
        routes.indices.contains(index)
      else { return }
      pager.show(routes[index].id)
    }
    .onChange(of: routes.map(\.id)) { old, new in
      guard !new.starts(with: old) else { return }
      align(width: alignedWidth)
    }
    .onChange(of: current) { align(width: alignedWidth) }
  }

  private static func pageIndex(_ geometry: ScrollGeometry) -> Int? {
    let width = geometry.containerSize.width
    guard width > 0 else { return nil }
    return Int((geometry.contentOffset.x / width).rounded())
  }

  private func align(width: CGFloat) {
    guard width > 0,
      let index = pager.routes.firstIndex(where: { $0.id == pager.current.id })
    else { return }
    position.scrollTo(x: CGFloat(index) * width)
    alignedWidth = width
  }

  private func showsImage(_ state: PutioPreviewState) -> Bool {
    if case .image = state { true } else { false }
  }

  private func showsDocument(_ state: PutioPreviewState) -> Bool {
    if case .document = state { true } else { false }
  }

  private func showsText(_ state: PutioPreviewState) -> Bool {
    if case .text = state { true } else { false }
  }

  private func showsBars(_ state: PutioPreviewState) -> Bool {
    !(barsHidden && showsImage(state) && !voiceOverEnabled)
  }

  private func toggleBars() {
    withAnimation(.easeInOut(duration: 0.2)) { barsHidden.toggle() }
  }

  @ViewBuilder
  private func topFade(_ state: PutioPreviewState) -> some View {
    if showsDocument(state) || showsText(state) {
      PutioPDFBarFade()
    } else if showsImage(state), showsBars(state) {
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

  private func bottomLabels(_ state: PutioPreviewState) -> some View {
    VStack(spacing: PutioTheme.Spacing.space2) {
      if showsDocument(state), let page = documentPages[pager.current.id], page.showsPill {
        PutioPDFPagePill(position: page)
      }
      if let position = pager.position, showsBars(state) {
        PutioPreviewPositionLabel(position: position)
          .transition(.opacity)
      }
    }
  }

  static let textLimitLabel = PutioFileRowModel.sizeText(
    bytes: Int64(PutioPreviewRoute.textLimitBytes))

  @ToolbarContentBuilder
  private func toolbar(_ model: PutioPreviewModel) -> some ToolbarContent {
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
      Text(model.title)
        .putioFont(PutioTheme.Typography.subheading)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("preview.title")
    }
    ToolbarItemGroup(placement: .topBarTrailing) {
      Group {
        if let share = model.share {
          ShareLink(item: share, preview: SharePreview(share.name)) { shareLabel }
        } else {
          Button {
          } label: {
            shareLabel
          }
          .disabled(true)
        }
      }
      .tint(PutioTheme.Colors.textPrimary)
      .accessibilityIdentifier("preview.share")
      PutioPreviewMoreMenu(
        menu: moreMenu(for: pager.item(for: model.route.id)),
        isDisabled: !itemActions.canStartAction || itemAction != nil
      )
    }
  }

  private func moreMenu(for item: PutioFileItem?) -> PutioItemMenu {
    guard let item else { return PutioItemMenu([]) }
    let rows = PutioFileMenu(
      item: item,
      capabilities: .init(
        canEdit: true, canDownload: false, vlcInstalled: false, tracksWatched: false)
    )
    var actions: [PutioItemAction] = []
    if rows.contains(.rename) {
      actions.append(
        PutioItemAction(id: "rename", title: String(localized: "Rename"), icon: .pencilSimple) {
          request(.rename(item))
        })
    }
    if rows.contains(.move) {
      actions.append(
        PutioItemAction(id: "move", title: String(localized: "Move"), icon: .folderSimpleDashed) {
          request(.move(item))
        })
    }
    if rows.contains(.trash) {
      actions.append(
        PutioItemAction(
          id: "trash",
          title: PutioFileDeletionCopy(trashEnabled: fileActions.trashEnabled).actionTitle,
          icon: .trash, role: .destructive, isDisabled: !itemActions.canDelete
        ) { requestRemoval(of: item) })
    }
    return PutioItemMenu([actions])
  }

  private func requestRemoval(of item: PutioFileItem) {
    guard itemActions.canDelete else { return }
    if fileActions.trashEnabled {
      remove(item, permanently: false)
    } else {
      confirmAlert = PutioFileDeletionCopy.permanentDeleteAlert(itemCount: 1) {
        remove(item, permanently: true)
      }
    }
  }

  private func remove(_ item: PutioFileItem, permanently: Bool) {
    actedOn = nil
    Task {
      await itemActions.delete(item, permanently: permanently)
      let outcome = itemActions.outcome
      itemActions.clearOutcome()
      switch outcome {
      case .succeeded(.delete):
        if pager.remove(item.id) {
          toast = removalToast(for: item, permanently: permanently, inViewer: true)
        } else {
          onDismiss()
          presentToast(removalToast(for: item, permanently: permanently, inViewer: false))
        }
      case .failed(.delete, _):
        toast = PutioToast(
          PutioFileDeletionPresentation(trashEnabled: fileActions.trashEnabled && !permanently)
            .singleFailureTitle)
      default:
        break
      }
    }
  }

  private func removalToast(
    for item: PutioFileItem, permanently: Bool, inViewer: Bool
  ) -> PutioToast {
    guard !permanently else { return PutioToast(PutioFileDeletionCopy.deleted) }
    return PutioToast(
      PutioFileDeletionCopy.trashed,
      action: PutioToast.Action(PutioFileDeletionCopy.undo) {
        undoTrash(of: item, inViewer: inViewer)
      })
  }

  private func undoTrash(of item: PutioFileItem, inViewer: Bool) {
    Task {
      do {
        try await fileActions.restore(item.id)
        if inViewer { pager.reinstate(item.id) }
      } catch {
        guard let failure = PutioFileActionFailure(restoring: item, error: error) else { return }
        if inViewer {
          toast = PutioToast(failure.title)
        } else {
          presentToast(PutioToast(failure.title))
        }
      }
    }
  }

  private func request(_ action: PutioFileItemActionRequest) {
    actedOn = pager.current.id
    itemAction = action
  }

  private func lookUpSettledFile() async {
    guard let id = lookup?.fileID else { return }
    for delay in [Duration.zero, .seconds(1), .seconds(3)] {
      do {
        try await Task.sleep(for: delay)
        pager.update(try await fileActions.lookUp(id))
        return
      } catch PutioRuntimeError.transient {
        continue
      } catch {
        return
      }
    }
  }

  private var shareLabel: some View {
    Label {
      Text("Share")
    } icon: {
      Image(putioIcon: .export)
    }
  }
}

struct PutioPreviewPage: View {
  let model: PutioPreviewModel
  let isCurrent: Bool
  let insets: EdgeInsets
  let onSingleTap: @MainActor () -> Void
  let onZoomChange: @MainActor (Bool) -> Void
  let onDocumentPage: @MainActor (PutioPDFPagePosition) -> Void

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityHidden(!isCurrent)
      .task(id: isCurrent) {
        guard isCurrent else { return }
        await model.loadIfNeeded()
      }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading where !isCurrent:
      Color.black
    case .loading:
      PutioLoadingStateView(title: String(localized: "Loading"), titleVisibility: .hidden)
        .ignoresSafeArea()
        .accessibilityIdentifier("preview.loading")
    case .image(let image):
      PutioZoomableImageView(
        image: image, title: model.title, onSingleTap: onSingleTap,
        onZoomChange: onZoomChange
      )
      .ignoresSafeArea()
      .accessibilityIdentifier("preview.image")
    case .document(let document):
      PutioPDFView(
        document: document, insets: verticalInsets, onPageChange: onDocumentPage,
        onZoomChange: onZoomChange
      )
      .padding(.leading, insets.leading)
      .padding(.trailing, insets.trailing)
      .accessibilityLabel(Text("\(model.title), \(document.pageCount) pages"))
      .accessibilityIdentifier("preview.document")
    case .text(let preview):
      PutioTextPreviewView(
        preview: preview,
        truncationNotice: PutioTextPreviewNotice(
          text: String(localized: "Showing the first \(PutioPreviewView.textLimitLabel)."),
          figure: PutioPreviewView.textLimitLabel),
        share: model.share,
        insets: verticalInsets
      )
      .padding(.leading, insets.leading)
      .padding(.trailing, insets.trailing)
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

extension PutioPreviewPage {
  fileprivate var verticalInsets: UIEdgeInsets {
    UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
  }
}

struct PutioPreviewPositionLabel: View {
  let position: PutioPreviewPosition

  var body: some View {
    Text(verbatim: position.text)
      .putioFont(PutioTheme.Typography.numeric)
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .padding(.vertical, PutioTheme.Spacing.space1)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityText)
      .accessibilityIdentifier("preview.position")
      .allowsHitTesting(false)
  }

  private var accessibilityText: Text {
    position.hasMore
      ? Text("\(position.number) of \(position.count) or more")
      : Text("\(position.number) of \(position.count)")
  }
}

/// UIScrollView zoom keeps the system's pinch, double-tap, and pan feel; SwiftUI
/// gestures cannot match its deceleration and bounds clamping.
struct PutioZoomableImageView: UIViewRepresentable {
  let image: UIImage
  let title: String
  let onSingleTap: @MainActor () -> Void
  var onZoomChange: @MainActor (Bool) -> Void = { _ in }

  func makeUIView(context: Context) -> PutioZoomingScrollView {
    let scrollView = PutioZoomingScrollView(image: image, title: title)
    scrollView.accessibilityLabel = title
    scrollView.onSingleTap = onSingleTap
    scrollView.onZoomChange = onZoomChange
    return scrollView
  }

  func updateUIView(_ scrollView: PutioZoomingScrollView, context: Context) {
    // SwiftUI re-runs this on unrelated invalidations; only a new image resets zoom.
    scrollView.update(image: image, title: title)
    scrollView.onSingleTap = onSingleTap
    scrollView.onZoomChange = onZoomChange
  }
}

final class PutioZoomingScrollView: UIScrollView, UIScrollViewDelegate {
  private let imageView = UIImageView()
  private var fittedSize: CGSize = .zero
  var onSingleTap: (@MainActor () -> Void)?
  var onZoomChange: (@MainActor (Bool) -> Void)?
  private var reportedZoomed = false

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
    reportZoom()
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

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    center()
    reportZoom()
  }

  private func reportZoom() {
    let zoomed = zoomScale > minimumZoomScale
    guard zoomed != reportedZoomed else { return }
    reportedZoomed = zoomed
    onZoomChange?(zoomed)
  }

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
  let share: PutioPreviewShareFile?
  var insets: UIEdgeInsets = .zero

  func makeUIView(context: Context) -> PutioTextPreviewContainer {
    PutioTextPreviewContainer()
  }

  func updateUIView(_ view: PutioTextPreviewContainer, context: Context) {
    view.show(preview, truncationNotice: truncationNotice)
    view.share = share
    view.safeInsets = insets
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
  private let shareButton = UIButton(configuration: .gray())
  private lazy var textElement = PutioVisibleTextElement(container: self, textView: textView)
  private var shown: PutioTextPreview?
  private var shownNotice: PutioTextPreviewNotice?

  private static let inset = PutioTheme.Spacing.space3
  private static let noticeSpacing = PutioTheme.Spacing.space3 + PutioTheme.Spacing.space2
  private static let noticeInset = PutioTheme.Spacing.space4
  private static let shareSpacing = PutioTheme.Spacing.space3

  var share: PutioPreviewShareFile? {
    didSet { shareButton.isEnabled = share != nil }
  }

  var safeInsets: UIEdgeInsets = .zero {
    didSet { if safeInsets != oldValue { setNeedsLayout() } }
  }
  private var placed = false

  init() {
    super.init(frame: .zero)
    clipsToBounds = true
    textView.delegate = self
    textView.isEditable = false
    textView.isSelectable = true
    textView.backgroundColor = .clear
    textView.alwaysBounceVertical = true
    textView.contentInsetAdjustmentBehavior = .never
    textView.topEdgeEffect.isHidden = true
    textView.textContainer.lineFragmentPadding = 0
    addSubview(textView)
    notice.numberOfLines = 0
    notice.accessibilityIdentifier = "preview.text.truncated"
    notice.isHidden = true
    addSubview(notice)
    shareButton.configuration?.cornerStyle = .capsule
    shareButton.configuration?.buttonSize = .large
    shareButton.configuration?.baseForegroundColor = UIColor(PutioTheme.Colors.textPrimary)
    shareButton.accessibilityIdentifier = "preview.text.share"
    shareButton.isHidden = true
    shareButton.isEnabled = false
    shareButton.addAction(
      UIAction { [weak self] _ in self?.presentShare() }, for: .primaryActionTriggered)
    addSubview(shareButton)
    registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
      (view: PutioTextPreviewContainer, _) in
      view.restyle()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func show(_ preview: PutioTextPreview, truncationNotice: PutioTextPreviewNotice) {
    notice.isHidden = !preview.isTruncated
    shareButton.isHidden = !preview.isTruncated
    accessibilityElements =
      preview.isTruncated ? [textElement, notice, shareButton] : [textElement]
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
    let body = PutioTheme.Typography.body.scaledUIFont(
      compatibleWith: traitCollection, fallback: UIFont.systemFont(ofSize:weight:)
    ).font
    shareButton.configuration?.title = String(localized: "Share")
    shareButton.configuration?.titleTextAttributesTransformer =
      UIConfigurationTextAttributesTransformer { incoming in
        var outgoing = incoming
        outgoing.font = body
        return outgoing
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
    let shareWidth = max(0, bounds.width - 2 * Self.inset)
    let shareHeight =
      shareButton.isHidden
      ? 0
      : shareButton.sizeThatFits(CGSize(width: shareWidth, height: .greatestFiniteMagnitude))
        .height
    let footer =
      notice.isHidden ? 0 : Self.noticeSpacing + noticeHeight + Self.footerHeight(shareHeight)
    let insets = UIEdgeInsets(
      top: Self.inset, left: Self.inset, bottom: footer + Self.noticeInset, right: Self.inset)
    if textView.textContainerInset != insets { textView.textContainerInset = insets }
    textView.insetToTop(safeInsets, placed: &placed)
    notice.frame.size = CGSize(width: width, height: noticeHeight)
    shareButton.frame.size = CGSize(width: shareWidth, height: shareHeight)
    placeNotice()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    placeNotice()
  }

  private static func footerHeight(_ shareHeight: CGFloat) -> CGFloat {
    shareHeight > 0 ? shareSpacing + shareHeight : 0
  }

  private func placeNotice() {
    guard !notice.isHidden else { return }
    let textEnd = textView.contentSize.height - textView.textContainerInset.bottom
    notice.frame.origin = CGPoint(
      x: Self.noticeInset,
      y: textEnd + Self.noticeSpacing - textView.contentOffset.y)
    shareButton.frame.origin = CGPoint(
      x: Self.inset, y: notice.frame.maxY + Self.shareSpacing)
  }

  private func presentShare() {
    guard let share, let presenter = presentingController else { return }
    let provider = NSItemProvider()
    provider.register(share)
    provider.suggestedName = share.name
    let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
    configuration.metadataProvider = { key in key == .title ? share.name : nil }
    let controller = UIActivityViewController(activityItemsConfiguration: configuration)
    controller.popoverPresentationController?.sourceItem = shareButton
    presenter.present(controller, animated: true)
  }

  private var presentingController: UIViewController? {
    var responder: UIResponder? = self
    while let current = responder {
      if let controller = current as? UIViewController {
        var top = controller
        while let presented = top.presentedViewController { top = presented }
        return top
      }
      responder = current.next
    }
    return nil
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
  var insets: UIEdgeInsets = .zero
  let onPageChange: @MainActor (PutioPDFPagePosition) -> Void
  var onZoomChange: @MainActor (Bool) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> PDFView {
    let view = PutioInsetPDFView()
    view.insets = insets
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
    context.coordinator.observe(view, onPageChange: onPageChange, onZoomChange: onZoomChange)
    return view
  }

  func updateUIView(_ view: PDFView, context: Context) {
    if view.document !== document { view.document = document }
    (view as? PutioInsetPDFView)?.insets = insets
    context.coordinator.observe(view, onPageChange: onPageChange, onZoomChange: onZoomChange)
  }

  static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator {
    private var observer: NSObjectProtocol?
    private var scaleObserver: NSObjectProtocol?
    private var onPageChange: (@MainActor (PutioPDFPagePosition) -> Void)?
    private var onZoomChange: (@MainActor (Bool) -> Void)?
    private var reported: PutioPDFPagePosition?
    private var reportedZoomed = false

    func observe(
      _ view: PDFView, onPageChange: @escaping @MainActor (PutioPDFPagePosition) -> Void,
      onZoomChange: @escaping @MainActor (Bool) -> Void
    ) {
      self.onPageChange = onPageChange
      self.onZoomChange = onZoomChange
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
      if scaleObserver == nil {
        scaleObserver = NotificationCenter.default.addObserver(
          forName: .PDFViewScaleChanged, object: view, queue: .main
        ) { [weak self, weak view] _ in
          MainActor.assumeIsolated {
            guard let self, let view else { return }
            self.reportZoom(view)
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
      if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
      observer = nil
      scaleObserver = nil
    }

    private func reportZoom(_ view: PDFView) {
      let zoomed = view.scaleFactor > view.scaleFactorForSizeToFit * 1.01
      guard zoomed != reportedZoomed else { return }
      reportedZoomed = zoomed
      onZoomChange?(zoomed)
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

final class PutioInsetPDFView: PDFView {
  var insets: UIEdgeInsets = .zero {
    didSet { if insets != oldValue { setNeedsLayout() } }
  }
  private var placed = false
  private var fittedSize: CGSize = .zero

  override func layoutSubviews() {
    super.layoutSubviews()
    if bounds.size != fittedSize, bounds.width > 0, bounds.height > 0 {
      if fittedSize != .zero, document != nil {
        scaleFactor = scaleFactorForSizeToFit
        autoScales = true
      }
      fittedSize = bounds.size
    }
    guard let scrollView = firstScrollView else { return }
    scrollView.topEdgeEffect.isHidden = true
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.insetToTop(insets, placed: &placed)
  }
}

extension UIScrollView {
  fileprivate func insetToTop(_ insets: UIEdgeInsets, placed: inout Bool) {
    let atTop = contentOffset.y <= -contentInset.top + 1
    if contentInset != insets {
      contentInset = insets
      verticalScrollIndicatorInsets = insets
      if atTop { contentOffset.y = -insets.top }
    }
    guard !placed, contentSize.height > 0 else { return }
    placed = true
    contentOffset.y = -insets.top
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
