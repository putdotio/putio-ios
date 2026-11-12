import Foundation

extension PutioFileRoute {
  public var previewKind: PutioPreviewRoute.Kind? {
    previewRoute?.kind
  }
}

public struct PutioPreviewSet: Equatable, Sendable {
  public let items: [PutioFileItem]
  public let index: Int

  public init?(
    items folderItems: [PutioFileItem], shownID: PutioFileID, kind: PutioPreviewRoute.Kind
  ) {
    let items = folderItems.filter { PutioFileRoute(item: $0).previewKind == kind }
    guard let index = items.firstIndex(where: { $0.id == shownID }) else { return nil }
    self.items = items
    self.index = index
  }

  public var pages: Bool { items.count > 1 }

  public func position(hasMore: Bool) -> PutioPreviewPosition? {
    guard pages else { return nil }
    return PutioPreviewPosition(number: index + 1, count: items.count, hasMore: hasMore)
  }
}

public struct PutioPreviewPosition: Equatable, Sendable {
  public let number: Int
  public let count: Int
  public let hasMore: Bool

  public var text: String {
    hasMore ? "\(number) / \(count)+" : "\(number) / \(count)"
  }
}

public struct PutioPreviewPageReads: Equatable, Sendable {
  public static let threshold = 5
  public static let fruitlessLimit = 3
  public static let failureLimit = 3

  public private(set) var fruitless = 0
  public private(set) var failures = 0
  private var wasAtLast = false

  public init() {}

  public var stopped: Bool { fruitless >= Self.fruitlessLimit }

  public mutating func shouldRead(index: Int, count: Int, hasMore: Bool) -> Bool {
    let atLast = index >= count - 1
    let arrived = atLast && !wasAtLast
    wasAtLast = atLast
    guard hasMore, index >= count - 1 - Self.threshold else { return false }
    if !stopped { return true }
    guard arrived else { return false }
    fruitless = 0
    return true
  }

  public mutating func didRead(countBefore: Int, countAfter: Int) {
    failures = 0
    fruitless = countAfter > countBefore ? 0 : fruitless + 1
  }

  public mutating func didFail() -> Duration? {
    failures += 1
    guard failures < Self.failureLimit else {
      failures = 0
      return nil
    }
    return .seconds(2 * failures)
  }
}

@MainActor
public struct PutioPreviewSource {
  public let items: @MainActor () -> [PutioFileItem]
  public let hasMore: @MainActor () -> Bool
  public let loadMore: @MainActor () async -> Bool

  public init(
    items: @escaping @MainActor () -> [PutioFileItem],
    hasMore: @escaping @MainActor () -> Bool,
    loadMore: @escaping @MainActor () async -> Bool
  ) {
    self.items = items
    self.hasMore = hasMore
    self.loadMore = loadMore
  }
}

extension PutioFolderModel {
  public var previewSource: PutioPreviewSource {
    PutioPreviewSource(
      items: { [weak self] in
        guard case .loaded(let contents) = self?.state else { return [] }
        return contents.items
      },
      hasMore: { [weak self] in self?.nextCursor != nil },
      loadMore: { [weak self] in await self?.loadMore() ?? false })
  }
}
