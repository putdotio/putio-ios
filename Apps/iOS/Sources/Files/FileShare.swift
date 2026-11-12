import AVFoundation
import Observation
import PutioCore
import SwiftUI
import UIKit

struct PutioFileShareAction {
  let localFile: @MainActor (PutioFileID) -> URL?
  let fetch: PutioPreviewDownload
}

extension EnvironmentValues {
  @Entry var putioFileShare: PutioFileShareAction? = nil
}

enum PutioFileShareFailure: Equatable {
  case retryable
  case final
}

struct PutioFileShareExportError: Error {}

@MainActor
@Observable
final class PutioFileShareModel {
  enum State: Equatable {
    case idle
    case fetching(PutioFileID)
    case presenting(PutioFileID, PutioSharedFile)
  }

  private(set) var state: State = .idle
  @ObservationIgnored private var fetch: Task<Void, Never>?
  @ObservationIgnored private var shown: PutioSharedFile?

  func isDownloaded(_ item: PutioFileItem, using action: PutioFileShareAction) -> Bool {
    action.localFile(item.id).flatMap(PutioSharedFile.init(local:)) != nil
  }

  func share(
    _ item: PutioFileItem, using action: PutioFileShareAction,
    onFailure: @escaping @MainActor (PutioFileShareFailure) -> Void
  ) -> Bool {
    cancel()
    let local = action.localFile(item.id).flatMap(PutioSharedFile.init(local:))
    switch PutioFileShareSource(item: item, isDownloaded: local != nil) {
    case .downloaded:
      guard let local else { return false }
      guard local.isPackage else {
        state = .presenting(item.id, local)
        return false
      }
      let kind = item.kind
      return begin(item.id, retryable: false, onFailure: onFailure) {
        try await Self.export(local.url, named: item.name, audio: kind == .audio)
      }
    case .fetch(let route):
      return begin(item.id, retryable: true, onFailure: onFailure) {
        let data = try await action.fetch(route, .whole)
        try Task.checkCancellation()
        return try await Self.stage(data, named: item.name)
      }
    case nil:
      return false
    }
  }

  private func begin(
    _ id: PutioFileID, retryable: Bool,
    onFailure: @escaping @MainActor (PutioFileShareFailure) -> Void,
    produce: @escaping @MainActor () async throws -> PutioSharedFile
  ) -> Bool {
    state = .fetching(id)
    fetch = Task { [weak self] in
      do {
        let file = try await produce()
        guard let self, !Task.isCancelled, state == .fetching(id) else {
          file.discard()
          return
        }
        state = .presenting(id, file)
      } catch {
        guard let self, !Task.isCancelled, state == .fetching(id) else { return }
        state = .idle
        switch PutioPreviewFailure.resolving(error) {
        case .loadFailed: onFailure(retryable ? .retryable : .final)
        case .cannotShow: onFailure(.final)
        case nil: break
        }
      }
    }
    return true
  }

  func cancel() {
    fetch?.cancel()
    fetch = nil
    if case .presenting(_, let file) = state { file.discard() }
    shown = nil
    state = .idle
  }

  func leave(_ id: PutioFileID? = nil) {
    switch state {
    case .idle: return
    case .fetching(let current):
      if id == nil || id == current { cancel() }
    case .presenting(let current, let file):
      if id == nil || id == current, shown != file { cancel() }
    }
  }

  func needsSheet(_ file: PutioSharedFile) -> Bool {
    guard case .presenting(_, let current) = state else { return false }
    return current == file && shown != file
  }

  func show(_ file: PutioSharedFile) { shown = file }

  func finish(_ file: PutioSharedFile) {
    file.discard()
    if case .presenting(_, let current) = state, current == file { state = .idle }
  }

  func presented(for id: PutioFileID) -> PutioSharedFile? {
    guard case .presenting(let current, let file) = state, current == id else { return nil }
    return file
  }

  @concurrent
  nonisolated private static func stage(_ data: Data, named name: String) async throws
    -> PutioSharedFile
  {
    try await PutioSharedFile.stage(data, named: name)
  }

  @concurrent
  nonisolated private static func export(_ package: URL, named name: String, audio: Bool)
    async throws -> PutioSharedFile
  {
    let exportName = PutioSharedFile.exportName(name, pathExtension: audio ? "m4a" : "mp4")
    return try await PutioSharedFile.stage(named: exportName) { file in
      guard
        let session = AVAssetExportSession(
          asset: AVURLAsset(url: package), presetName: AVAssetExportPresetPassthrough)
      else { throw PutioFileShareExportError() }
      try await session.export(to: file, as: audio ? .m4a : .mp4)
    }
  }
}

struct PutioShareSheetAnchor: UIViewRepresentable {
  let file: PutioSharedFile
  let name: String
  let model: PutioFileShareModel

  func makeUIView(context: Context) -> PutioShareSheetAnchorView {
    PutioShareSheetAnchorView()
  }

  func updateUIView(_ view: PutioShareSheetAnchorView, context: Context) {
    view.request(file, named: name, model: model)
  }
}

final class PutioShareSheetAnchorView: UIView {
  private var file: PutioSharedFile?
  private var name = String()
  private weak var model: PutioFileShareModel?

  init() {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func request(_ file: PutioSharedFile, named name: String, model: PutioFileShareModel) {
    self.file = file
    self.name = name
    self.model = model
    presentWhenReady()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    presentWhenReady()
  }

  private func presentWhenReady() {
    guard window != nil, let file, let model, model.needsSheet(file) else { return }
    model.show(file)
    Task { @MainActor [weak self] in
      for _ in 0..<40 {
        guard let self, window != nil else { break }
        if let presenter = topController, presenter.transitionCoordinator == nil,
          !presenter.isBeingDismissed
        {
          present(file, from: presenter)
          return
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
      model.finish(file)
    }
  }

  private func present(_ file: PutioSharedFile, from presenter: UIViewController) {
    let provider = NSItemProvider(contentsOf: file.url) ?? NSItemProvider()
    provider.suggestedName = file.isTemporary ? file.url.lastPathComponent : name
    let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
    let title = provider.suggestedName
    configuration.metadataProvider = { key in key == .title ? title : nil }
    let controller = UIActivityViewController(activityItemsConfiguration: configuration)
    controller.popoverPresentationController?.sourceView = self
    controller.popoverPresentationController?.sourceRect = bounds
    let model = model
    controller.completionWithItemsHandler = { activity, completed, _, _ in
      guard completed || activity == nil else { return }
      MainActor.assumeIsolated {
        if let model { model.finish(file) } else { file.discard() }
      }
    }
    presenter.present(controller, animated: true)
  }

  private var topController: UIViewController? {
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
