import PutioCore
import SwiftUI

@MainActor
struct PlaybackPreferencesView: View {
  let runtime: PutioRuntime
  let appConfig: PutioAppConfigModel
  @State private var model: PutioAccountPreferencesModel
  @State private var routes: [PutioPlaybackRoute]?
  @State private var routeFailure: String?
  @State private var isLoadingRoutes = false
  @State private var routeGeneration = 0

  init(runtime: PutioRuntime, appConfig: PutioAppConfigModel) {
    self.runtime = runtime
    self.appConfig = appConfig
    _model = State(initialValue: PutioAccountPreferencesModel(actions: .init(runtime: runtime)))
  }

  var body: some View {
    Form {
      if model.isStale {
        Section {
          Text(
            model.failure ?? "Account settings could not be confirmed. Refresh to continue."
          )
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          Button(model.isRefreshing ? "Refreshing…" : "Refresh account") {
            Task { await model.retryRefresh() }
          }
          .disabled(model.isBusy)
          .accessibilityIdentifier("playback-settings.refresh")
        }
        .listRowBackground(PutioTheme.Colors.surface)
      } else if let failure = model.failure {
        Section {
          Text(failure).foregroundStyle(PutioTheme.Colors.textSecondary)
          if model.failedMutation != nil {
            Button("Try again") { Task { await model.retrySave() } }
              .disabled(model.isBusy)
              .accessibilityIdentifier("playback-settings.retry-save")
          }
        }
        .listRowBackground(PutioTheme.Colors.surface)
      }
      if let account = model.account {
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
            .pickerStyle(.navigationLink)
            .disabled(!model.canSave || isLoadingRoutes)
            .accessibilityIdentifier("playback-settings.route")
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
        } header: {
          Text("Connection")
        } footer: {
          Text("The selected proxy applies when you open media again.")
        }
        .listRowBackground(PutioTheme.Colors.surface)
        Section {
          Toggle("Show subtitles", isOn: showSubtitles)
            .accessibilityIdentifier("playback-settings.subtitles")
          if !account.hideSubtitles {
            Toggle("Do not select subtitles by default", isOn: dontAutoSelectSubtitles)
              .accessibilityIdentifier("playback-settings.subtitle-selection")
          }
        } header: {
          Text("Subtitles")
        }
        .disabled(!model.canSave)
        .listRowBackground(PutioTheme.Colors.surface)
        Section {
          if appConfig.config != nil {
            Toggle("Autoplay next video", isOn: autoplayNextVideo)
              .disabled(!appConfig.canSave)
              .accessibilityIdentifier("playback-settings.autoplay")
          } else if appConfig.isLoading {
            ProgressView("Loading playback settings")
          }
          if let failure = appConfig.failure {
            Text(failure).foregroundStyle(PutioTheme.Colors.textSecondary)
            Button("Try again") { Task { await appConfig.retry() } }
              .disabled(appConfig.isBusy)
              .accessibilityIdentifier("playback-settings.retry-autoplay")
          }
        } header: {
          Text("Next video")
        } footer: {
          Text(
            account.suggestNextVideo
              ? "The next video is suggested when one ends. With autoplay on, it starts after a short countdown."
              : "Next video suggestions are turned off in your put.io account settings."
          )
        }
        .listRowBackground(PutioTheme.Colors.surface)
      }
      if model.isSaving || appConfig.isSaving {
        ProgressView("Saving settings")
          .listRowBackground(PutioTheme.Colors.surface)
      }
    }
    .navigationTitle("Playback Preferences")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .task { if routes == nil { await loadRoutes() } }
    .task { await appConfig.loadIfNeeded() }
  }

  private var autoplayNextVideo: Binding<Bool> {
    Binding(
      get: { appConfig.autoplayNextVideo },
      set: { enabled in Task { await appConfig.setAutoplayNextVideo(enabled) } })
  }

  private var routeSelection: Binding<String> {
    Binding(
      get: { model.account?.routeName ?? "default" },
      set: { name in
        guard name != model.account?.routeName else { return }
        Task { await model.save(.route(name)) }
      })
  }

  private var showSubtitles: Binding<Bool> {
    Binding(
      get: { !(model.account?.hideSubtitles ?? false) },
      set: { visible in Task { await model.save(.showSubtitles(visible)) } })
  }

  private var dontAutoSelectSubtitles: Binding<Bool> {
    Binding(
      get: { model.account?.dontAutoSelectSubtitles ?? false },
      set: { disabled in Task { await model.save(.dontAutoSelectSubtitles(disabled)) } })
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
