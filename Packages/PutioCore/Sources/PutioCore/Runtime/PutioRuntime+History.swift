import Foundation
import PutioSDK

extension PutioRuntime {
  public func listHistory(before: Int? = nil) async throws -> PutioHistoryPage {
    if let before, before <= 0 { throw PutioRuntimeError.invalidResponse }
    let response = try await performAuthenticatedOperation {
      try await sdk.getHistoryEvents(query: PutioHistoryEventsQuery(perPage: 50, before: before))
    }
    guard response.status == "OK", response.events.allSatisfy({ $0.id > 0 }) else {
      throw PutioRuntimeError.invalidResponse
    }
    var nextBefore: Int?
    if response.hasMore {
      guard let lastID = response.events.last?.id, before.map({ lastID < $0 }) ?? true else {
        throw PutioRuntimeError.invalidResponse
      }
      nextBefore = lastID
    }
    return PutioHistoryPage(
      items: response.events.compactMap(historySnapshot), nextBefore: nextBefore)
  }

  public func deleteHistoryEvent(id: Int) async throws {
    guard id > 0 else { throw PutioRuntimeError.invalidResponse }
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.deleteHistoryEvent(eventID: id)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }

  public func clearHistory() async throws {
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.clearHistoryEvents()
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }

  private func historySnapshot(_ event: PutioHistoryEvent) -> PutioHistoryEventItem? {
    let kind: PutioHistoryEventKind
    switch event {
    case let event as PutioUploadEvent:
      kind = .upload(
        name: event.fileName, sizeBytes: event.fileSize, fileID: historyFileID(event.fileID))
    case let event as PutioFileSharedEvent:
      kind = .fileShared(
        name: event.fileName, sharingUserName: event.sharingUserName,
        fileID: historyFileID(event.fileID))
    case let event as PutioTransferCompletedEvent:
      kind = .transferCompleted(
        name: event.transferName, sizeBytes: event.transferSize, fileID: historyFileID(event.fileID)
      )
    case let event as PutioTransferErrorEvent:
      kind = .transferError(name: event.transferName)
    case let event as PutioFileFromRSSDeletedErrorEvent:
      kind = .fileFromRSSDeleted(name: event.fileName, sizeBytes: event.fileSize)
    case let event as PutioRSSFilterPausedEvent:
      kind = .rssFilterPaused(title: event.rssFilterTitle)
    case let event as PutioTransferFromRSSErrorEvent:
      kind = .transferFromRSSError(name: event.transferName)
    case let event as PutioTransferCallbackErrorEvent:
      kind = .transferCallbackError(name: event.transferName)
    default:
      return nil
    }
    return PutioHistoryEventItem(id: event.id, createdAt: event.createdAt, kind: kind)
  }

  private func historyFileID(_ value: Int) -> PutioFileID? {
    value > 0 ? PutioFileID(rawValue: value) : nil
  }
}
