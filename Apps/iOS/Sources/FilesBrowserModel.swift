import Foundation
import Observation
import PutioCore

typealias PutioFolderLoad =
  @MainActor @Sendable (PutioFileID) async throws -> PutioFolderContents

struct PutioFolderRoute: Identifiable, Sendable {
  let id: PutioFileID
  let title: String

  static let root = PutioFolderRoute(id: .root, title: "Files")
}

extension PutioFolderRoute: Hashable {
  static func == (lhs: PutioFolderRoute, rhs: PutioFolderRoute) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

struct PutioFileRoute: Identifiable, Hashable, Sendable {
  let item: PutioFileItem

  var id: PutioFileID {
    item.id
  }

  var videoPlaybackRoute: PutioFileRoute? {
    item.kind == .video ? self : nil
  }
}

enum PutioBrowserErrorKind: Hashable, Sendable {
  case notFound
  case rateLimited
  case transient
  case invalidResponse
  case unknown
}

struct PutioBrowserErrorPresentation: Equatable, Sendable {
  let kind: PutioBrowserErrorKind
  let title: String
  let message: String

  init?(error: Error) {
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired:
      return nil
    case .notFound:
      self.init(
        kind: .notFound,
        title: "Folder not found",
        message: "It may have been moved or deleted."
      )
    case .rateLimited:
      self.init(
        kind: .rateLimited,
        title: "Could not load files",
        message: "put.io is receiving too many requests. Try again shortly."
      )
    case .transient:
      self.init(
        kind: .transient,
        title: "Could not load files",
        message: "Check your connection and try again."
      )
    case .invalidResponse:
      self.init(
        kind: .invalidResponse,
        title: "Could not load files",
        message: "put.io returned an invalid response. Try again."
      )
    case .unknown, nil:
      self.init(
        kind: .unknown,
        title: "Could not load files",
        message: "put.io could not complete the request. Try again."
      )
    }
  }

  private init(kind: PutioBrowserErrorKind, title: String, message: String) {
    self.kind = kind
    self.title = title
    self.message = message
  }
}

enum PutioFolderLoadState: Equatable, Sendable {
  case loading
  case loaded(PutioFolderContents)
  case failed(PutioBrowserErrorPresentation)
}

@MainActor
@Observable
final class PutioFolderModel {
  let folderID: PutioFileID

  private(set) var state: PutioFolderLoadState
  private(set) var refreshFailure: PutioBrowserErrorPresentation?

  @ObservationIgnored private let load: PutioFolderLoad
  @ObservationIgnored private var generation: UInt64 = 0

  init(
    folderID: PutioFileID,
    load: @escaping PutioFolderLoad,
    initialContents: PutioFolderContents? = nil
  ) {
    self.folderID = folderID
    self.load = load
    state = initialContents.map { .loaded($0) } ?? .loading
  }

  func loadIfNeeded() async {
    // `.loading` means the initial attempt never settled — including a
    // cancelled attempt that is still unwinding when the screen is
    // re-entered. Starting a new request here supersedes that unwind via
    // the generation check, so a late restore cannot strand the spinner.
    guard case .loading = state else { return }
    await performLoad(mode: .replace)
  }

  func retry() async {
    await performLoad(mode: .replace)
  }

  func refresh() async {
    guard case .loaded = state else { return }
    await performLoad(mode: .refresh)
  }

  private func performLoad(mode: LoadMode) async {
    let previousState = state
    let previousRefreshFailure = refreshFailure
    generation += 1
    let requestGeneration = generation

    switch mode {
    case .replace:
      state = .loading
      refreshFailure = nil
    case .refresh:
      refreshFailure = nil
    }

    do {
      try Task.checkCancellation()
      let contents = try await load(folderID)
      try Task.checkCancellation()
      guard requestGeneration == generation else { return }
      state = .loaded(contents)
      refreshFailure = nil
    } catch {
      guard requestGeneration == generation else { return }
      if Task.isCancelled {
        state = previousState
        refreshFailure = previousRefreshFailure
        return
      }

      guard let presentation = PutioBrowserErrorPresentation(error: error) else {
        state = previousState
        refreshFailure = nil
        return
      }
      switch mode {
      case .replace:
        state = .failed(presentation)
        refreshFailure = nil
      case .refresh:
        state = previousState
        refreshFailure = presentation
      }
    }
  }
}

private enum LoadMode {
  case replace
  case refresh
}

struct PutioBrowserItemPresentation: Equatable, Identifiable, Sendable {
  let item: PutioFileItem
  let row: PutioFileRowModel

  var id: PutioFileID {
    item.id
  }

  var folderRoute: PutioFolderRoute? {
    guard item.kind == .folder else { return nil }
    return PutioFolderRoute(id: item.id, title: item.name)
  }

  var fileRoute: PutioFileRoute? {
    guard item.kind != .folder else { return nil }
    return PutioFileRoute(item: item)
  }

  init(
    item: PutioFileItem,
    relativeTo referenceDate: Date = .now,
    locale: Locale = .current
  ) {
    self.item = item
    row = PutioFileRowModel(
      name: item.name,
      kind: Self.rowKind(for: item.kind),
      sizeText: Self.detailText(for: item, relativeTo: referenceDate, locale: locale),
      isWatched: item.isWatched
    )
  }

  private static func rowKind(for kind: PutioFileKind) -> PutioFileRowModel.Kind {
    switch kind {
    case .folder: .folder
    case .video: .video
    case .audio: .audio
    case .image: .image
    case .pdf, .other: .file
    }
  }

  private static func detailText(
    for item: PutioFileItem,
    relativeTo referenceDate: Date,
    locale: Locale
  ) -> String? {
    guard item.kind != .folder else { return nil }
    let size = PutioFileRowModel.sizeText(bytes: item.sizeBytes, locale: locale)
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .full
    let relativeDate = formatter.localizedString(for: item.updatedAt, relativeTo: referenceDate)
    return "\(size) · \(relativeDate)"
  }
}
