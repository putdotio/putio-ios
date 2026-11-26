import Foundation
import Observation

/// The routes a proxy chooser offers: Direct first, then routes put.io
/// describes, then bare locations. A current route put.io no longer lists
/// stays choosable at the top of the suggestions.
public struct PutioProxyChoices: Equatable, Sendable {
  public static let directRouteName = "default"

  public let suggested: [PutioPlaybackRoute]
  public let locations: [PutioPlaybackRoute]

  public init(routes: [PutioPlaybackRoute], current: String) {
    let listed = routes.filter { $0.name != Self.directRouteName }
    let unlisted =
      current.isEmpty || current == Self.directRouteName || routes.contains { $0.name == current }
      ? [] : [PutioPlaybackRoute(name: current, description: "")]
    suggested = unlisted + listed.filter(\.hasOwnDescription)
    locations = listed.filter { !$0.hasOwnDescription }
  }

  /// Every choosable route name in display order.
  public var names: [String] {
    [Self.directRouteName] + suggested.map(\.name) + locations.map(\.name)
  }

  /// The description put.io gives a suggested route, if any.
  public func description(for name: String) -> String? {
    guard name != Self.directRouteName,
      let route = suggested.first(where: { $0.name == name }), route.hasOwnDescription
    else { return nil }
    return route.description
  }

  public static func title(for routeName: String) -> String {
    routeName.isEmpty || routeName == directRouteName
      ? String(localized: "Direct", bundle: .module) : routeName
  }

  public static var directDescription: String {
    String(localized: "Straight from put.io, no proxy.", bundle: .module)
  }

  public static var summary: String {
    String(
      localized: "Route streams and downloads through a put.io proxy closer to you.",
      bundle: .module)
  }

  public static var unavailableTitle: String {
    String(localized: "That proxy isn’t available for your account.", bundle: .module)
  }

  public static var unavailableMessage: String {
    String(localized: "Choose another one.", bundle: .module)
  }
}

public struct PutioProxyChooserActions: Sendable {
  let listRoutes: @MainActor @Sendable () async throws -> [PutioPlaybackRoute]

  public init(runtime: PutioRuntime) {
    listRoutes = { try await runtime.listPlaybackRoutes() }
  }

  init(listRoutes: @escaping @MainActor @Sendable () async throws -> [PutioPlaybackRoute]) {
    self.listRoutes = listRoutes
  }
}

/// Loads put.io's routes and saves the chosen one through the account
/// preferences, one selection at a time.
@MainActor
@Observable
public final class PutioProxyChooserModel {
  public private(set) var routes: [PutioPlaybackRoute]?
  public private(set) var loadFailure: String?
  public private(set) var isLoadingRoutes = false
  public private(set) var pendingRoute: String?
  /// The last route chosen, kept through failed saves and their retries.
  public private(set) var requestedRoute: String?
  public let preferences: PutioAccountPreferencesModel
  @ObservationIgnored private let actions: PutioProxyChooserActions
  @ObservationIgnored private var generation = 0

  public init(actions: PutioProxyChooserActions, preferences: PutioAccountPreferencesModel) {
    self.actions = actions
    self.preferences = preferences
  }

  /// The account's route, with an empty name read as Direct.
  public var currentRoute: String {
    let name = preferences.account?.routeName ?? ""
    return name.isEmpty ? PutioProxyChoices.directRouteName : name
  }

  public var choices: PutioProxyChoices? {
    routes.map { PutioProxyChoices(routes: $0, current: currentRoute) }
  }

  /// The route the chooser marks: the one being saved, else the account's.
  public var selection: String { pendingRoute ?? currentRoute }

  public var canSelect: Bool { preferences.canSave && pendingRoute == nil && !isLoadingRoutes }

  public var isBusy: Bool { isLoadingRoutes || preferences.isBusy }

  /// The failure the chooser shows: route loading first, then saving.
  public var failure: String? { loadFailure ?? preferences.failure }

  public func loadIfNeeded() async {
    guard routes == nil else { return }
    await loadRoutes()
  }

  public func loadRoutes() async {
    generation += 1
    let current = generation
    isLoadingRoutes = true
    loadFailure = nil
    defer { if current == generation { isLoadingRoutes = false } }
    do {
      let loaded = try await actions.listRoutes()
      try Task.checkCancellation()
      guard current == generation else { return }
      routes = loaded
    } catch {
      guard current == generation, !Task.isCancelled,
        let presentation = PutioBrowserErrorPresentation(error: error)
      else { return }
      loadFailure = presentation.message
    }
  }

  /// The chosen route is the account's confirmed route, once any retry of
  /// its save or refresh has settled.
  public var isRequestConfirmed: Bool {
    guard let requestedRoute else { return false }
    return currentRoute == requestedRoute && !preferences.isStale && !preferences.isBusy
  }

  /// Saves `name` as the account's route. Choosing the current route, or
  /// choosing while another save runs, is skipped.
  @discardableResult
  public func select(_ name: String) async -> PutioSettingSaveOutcome {
    guard canSelect, name != currentRoute else { return .skipped }
    requestedRoute = name
    pendingRoute = name
    defer { pendingRoute = nil }
    return await preferences.save(.route(name))
  }

  /// Retries whatever failed: the route list, the stale account, or the save.
  public func retry() async {
    if loadFailure != nil {
      await loadRoutes()
    } else {
      await preferences.retry()
    }
  }
}
