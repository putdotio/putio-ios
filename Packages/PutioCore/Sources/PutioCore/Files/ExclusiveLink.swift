import Foundation
import Observation

public enum PutioPublicLinkRefusal: Error, Equatable, Sendable, CaseIterable {
  case plan
  case fileType
  case linkLimit
  case folderSize
  case folderChildren
  case daily
  case weekly

  init?(apiErrorType: String?) {
    switch apiErrorType {
    case "PUBLIC_SHARE_NOT_ALLOWED_PLAN": self = .plan
    case "PUBLIC_SHARE_UNSUPPORTED_FILE_TYPE": self = .fileType
    case "PUBLIC_SHARE_EXCEEDED_LIMIT", "PUBLIC_SHARE_SINGLE_FILE_LIMIT_EXCEEDED",
      "PUBLIC_SHARE_FOLDER_LINK_COUNT_LIMIT_EXCEEDED":
      self = .linkLimit
    case "PUBLIC_SHARE_FOLDER_MAX_SIZE_LIMIT_EXCEEDED": self = .folderSize
    case "PUBLIC_SHARE_FOLDER_MAX_CHILDREN_LIMIT_EXCEEDED": self = .folderChildren
    case "PUBLIC_SHARE_DAILY_TOTAL_LINK_COUNT_EXCEEDED": self = .daily
    case "PUBLIC_SHARE_WEEKLY_TOTAL_LINK_COUNT_EXCEEDED": self = .weekly
    default: return nil
    }
  }

  public var message: String {
    switch self {
    case .plan:
      String(localized: "You can’t create public links with your current plan.", bundle: .module)
    case .fileType:
      String(localized: "This file type can’t be shared.", bundle: .module)
    case .linkLimit:
      String(
        localized:
          "You have reached the limit of your public links. You’ll have to revoke some under Account, Exclusive access, if you want to make more.",
        bundle: .module)
    case .folderSize:
      String(localized: "This folder is too big to share.", bundle: .module)
    case .folderChildren:
      String(localized: "This folder contains too many files to share.", bundle: .module)
    case .daily:
      String(
        localized: "You have reached the daily public link creation limit.", bundle: .module)
    case .weekly:
      String(
        localized: "You have reached the weekly public link creation limit.", bundle: .module)
    }
  }
}

public typealias PutioPublicLinkCreate = @MainActor @Sendable (PutioFileID) async throws -> URL
public typealias PutioPublicLinkFind =
  @MainActor @Sendable (PutioFileID) async throws -> PutioPublicLink?

public struct PutioExclusiveLinkActions: Sendable {
  let find: PutioPublicLinkFind
  let create: PutioPublicLinkCreate

  public init(runtime: PutioRuntime) {
    find = { try await runtime.livePublicLink(fileID: $0) }
    create = { try await runtime.createPublicLink(fileID: $0) }
  }

  init(find: @escaping PutioPublicLinkFind, create: @escaping PutioPublicLinkCreate) {
    self.find = find
    self.create = create
  }
}

public enum PutioExclusiveLinkCopy {
  static let hours = "72"
  static let nameLimit = 32
  static let namePrefix = 18
  static let nameSuffix = 11

  public static func displayName(_ name: String) -> String {
    guard name.count > nameLimit else { return name }
    return "\(name.prefix(namePrefix))…\(name.suffix(nameSuffix))"
  }

  public static func body(name: String) -> String {
    let hours = hours
    return String(
      localized:
        "Anyone with a link can open \(name). A link stops working after \(hours) hours, or sooner when it hits its IP or data limit.",
      bundle: .module)
  }

  public static func address(_ url: URL) -> String {
    let text = url.absoluteString
    guard let scheme = url.scheme else { return text }
    return String(text.dropFirst(scheme.count + 3))
  }
}

@MainActor
@Observable
public final class PutioExclusiveLinkModel {
  public enum State: Equatable {
    case finding
    case ready
    case creating
    case created(URL)
    case refused(PutioPublicLinkRefusal)
    case failed(String)
  }

  public let item: PutioFileItem
  public private(set) var state: State = .finding
  public private(set) var expiresAt: Date?
  @ObservationIgnored private let actions: PutioExclusiveLinkActions
  @ObservationIgnored private var findGeneration = 0

  init(item: PutioFileItem, actions: PutioExclusiveLinkActions) {
    self.item = item
    self.actions = actions
  }

  var outlivesTheSheet: Bool {
    switch state {
    case .creating, .created: true
    case .finding, .ready, .refused, .failed: false
    }
  }

  public var canCreate: Bool {
    switch state {
    case .ready, .refused, .failed: true
    case .finding, .creating, .created: false
    }
  }

  public func findExisting() async {
    guard state != .creating else { return }
    findGeneration += 1
    let generation = findGeneration
    let fallback: State
    if case .created = state { fallback = state } else { fallback = .ready }
    state = .finding
    let found: PutioPublicLink?
    do {
      found = try await actions.find(item.id)
    } catch {
      guard generation == findGeneration else { return }
      state = fallback
      return
    }
    guard generation == findGeneration else { return }
    expiresAt = found?.expiresAt
    state = found.map { .created($0.url) } ?? .ready
  }

  public func start() -> Bool {
    guard canCreate else { return false }
    state = .creating
    return true
  }

  public func create() async {
    guard state == .creating else { return }
    do {
      let url = try await actions.create(item.id)
      expiresAt = nil
      state = .created(url)
    } catch let refusal as PutioPublicLinkRefusal {
      state = .refused(refusal)
    } catch {
      guard let reason = PutioAccountSecurityPresentation.message(for: error) else {
        state = .ready
        return
      }
      state = .failed(String(localized: "Couldn’t create a link. \(reason)", bundle: .module))
    }
  }
}

@MainActor
public final class PutioExclusiveLinks {
  private var models: [PutioFileID: PutioExclusiveLinkModel] = [:]

  public init() {}

  public func model(
    for item: PutioFileItem, actions: PutioExclusiveLinkActions
  ) -> PutioExclusiveLinkModel {
    if let model = models[item.id] { return model }
    let model = PutioExclusiveLinkModel(item: item, actions: actions)
    models[item.id] = model
    return model
  }

  public func sheetClosed() {
    models = models.filter { $0.value.outlivesTheSheet }
  }
}
