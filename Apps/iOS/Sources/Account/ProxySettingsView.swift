import PutioCore
import SwiftUI

@MainActor
struct ProxySettingsView: View {
  let runtime: PutioRuntime
  let preferences: PutioAccountPreferencesModel
  @Environment(\.dismiss) private var dismiss
  @State private var routes: [PutioPlaybackRoute]?
  @State private var routeFailure: String?
  @State private var isLoadingRoutes = false
  @State private var routeGeneration = 0

  var body: some View {
    Form {
      if let account = preferences.account {
        Section {
          if let routes {
            Picker("Proxy", selection: routeSelection) {
              if !routes.contains(where: { $0.name == account.routeName }) {
                Text(account.routeName).tag(account.routeName)
              }
              ForEach(routes) { route in
                Text(route.description.isEmpty ? route.name : route.description)
                  .tag(route.name)
                  .accessibilityIdentifier("playback-settings.route.\(route.name)")
              }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(!preferences.canSave || isLoadingRoutes)
          } else {
            LabeledContent("Current proxy", value: account.routeName)
          }
          if isLoadingRoutes {
            ProgressView("Loading proxies")
          }
          if let routeFailure {
            Text(routeFailure).foregroundStyle(PutioTheme.Colors.textSecondary)
            Button("Try again") { Task { await loadRoutes() } }
              .disabled(isLoadingRoutes)
              .accessibilityIdentifier("playback-settings.retry-routes")
          }
        } footer: {
          Text("The selected proxy applies when you open media again.")
        }
        .listRowBackground(PutioTheme.Colors.surface)
      }
    }
    .navigationTitle("Proxy")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .task { if routes == nil { await loadRoutes() } }
  }

  private var routeSelection: Binding<String> {
    Binding(
      get: { preferences.account?.routeName ?? "default" },
      set: { name in
        guard name != preferences.account?.routeName else { return }
        dismiss()
        Task { await preferences.save(.route(name)) }
      })
  }

  private func loadRoutes() async {
    routeGeneration += 1
    let generation = routeGeneration
    isLoadingRoutes = true
    routeFailure = nil
    defer { if generation == routeGeneration { isLoadingRoutes = false } }
    do {
      let loaded = try await runtime.listPlaybackRoutes()
      try Task.checkCancellation()
      guard generation == routeGeneration else { return }
      routes = loaded
    } catch {
      guard generation == routeGeneration, !Task.isCancelled,
        let failure = PutioBrowserErrorPresentation(error: error)
      else { return }
      routeFailure = failure.message
    }
  }
}
