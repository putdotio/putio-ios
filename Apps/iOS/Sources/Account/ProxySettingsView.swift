import PutioCore
import SwiftUI

@MainActor
struct ProxySettingsView: View {
  let runtime: PutioRuntime
  let preferences: PutioAccountPreferencesModel
  @State private var routes: [PutioPlaybackRoute]?
  @State private var loadFailed = false
  @State private var routeGeneration = 0
  @State private var pendingRoute: String?
  @State private var refusesRoute = false
  @State private var saveFailures = PutioSettingSaveFailures()

  var body: some View {
    List {
      Group {
        if let routes {
          routeSections(PutioProxyChoices(routes: routes, current: currentRoute))
        } else if loadFailed {
          PutioSettingsSection(Self.summary) {
            PutioSettingsFailedRows(
              String(localized: "Couldn’t load proxies"),
              identifier: "proxy.failed",
              retryIdentifier: "proxy.retry"
            ) {
              Task { await loadRoutes() }
            }
          }
        } else {
          PutioSettingsSection(Self.summary) {
            PutioSettingsLoadingRow(String(localized: "Loading proxies…"))
              .accessibilityIdentifier("proxy.loading")
          }
        }
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle(String(localized: "Choose your proxy"))
    .navigationBarTitleDisplayMode(.inline)
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .putioSettingSaveFailures(saveFailures)
    .putioAlert(
      String(localized: "That proxy isn’t available for your account."),
      isPresented: $refusesRoute,
      message: String(localized: "Choose another one."),
      actions: [
        PutioAlertAction(String(localized: "OK"), tier: .neutral, id: "proxy.unavailable-dismiss")
      ]
    )
    .task { if routes == nil { await loadRoutes() } }
  }

  @ViewBuilder private func routeSections(_ choices: PutioProxyChoices) -> some View {
    PutioSettingsSection(Self.summary) {
      PutioChoiceList(
        selection: selection,
        options: [PutioProxyChoices.directRouteName] + choices.suggested.map(\.name)
      ) { name in
        guard name != PutioProxyChoices.directRouteName else {
          return PutioChoice(
            PutioProxyChoices.title(for: name),
            description: String(localized: "Straight from put.io, no proxy."))
        }
        let description = choices.suggested.first { $0.name == name }?.description
        return PutioChoice(name, description: description?.isEmpty == false ? description : nil)
      }
      .disabled(!canSelect)
    }
    PutioSettingsSection {
      PutioChoiceList(selection: selection, options: choices.locations.map(\.name)) { name in
        PutioChoice(name)
      }
      .disabled(!canSelect)
    }
  }

  private static var summary: String {
    String(localized: "Route streams and downloads through a put.io proxy closer to you.")
  }

  private var canSelect: Bool { preferences.canSave && pendingRoute == nil }

  private var currentRoute: String {
    let name = preferences.account?.routeName ?? ""
    return name.isEmpty ? PutioProxyChoices.directRouteName : name
  }

  private var selection: Binding<String> {
    Binding(get: { pendingRoute ?? currentRoute }, set: { select($0) })
  }

  private func select(_ name: String) {
    guard canSelect, name != currentRoute else { return }
    pendingRoute = name
    Task {
      let outcome = await preferences.save(.route(name))
      pendingRoute = nil
      switch outcome {
      case .failed: saveFailures.report()
      case .unavailable: refusesRoute = true
      case .saved, .savedUnconfirmed, .skipped: break
      }
    }
  }

  private func loadRoutes() async {
    routeGeneration += 1
    let generation = routeGeneration
    loadFailed = false
    do {
      let loaded = try await runtime.listPlaybackRoutes()
      try Task.checkCancellation()
      guard generation == routeGeneration else { return }
      routes = loaded
    } catch {
      guard generation == routeGeneration, !Task.isCancelled else { return }
      loadFailed = PutioBrowserErrorPresentation(error: error) != nil
    }
  }
}

extension PutioProxyChoices {
  static func title(for routeName: String) -> String {
    routeName.isEmpty || routeName == directRouteName ? String(localized: "Direct") : routeName
  }
}
