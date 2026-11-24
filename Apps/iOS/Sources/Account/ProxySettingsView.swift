import PutioCore
import SwiftUI

@MainActor
struct ProxySettingsView: View {
  @State private var model: PutioProxyChooserModel
  @State private var refusesRoute = false
  @State private var saveFailures = PutioSettingSaveFailures()

  init(runtime: PutioRuntime, preferences: PutioAccountPreferencesModel) {
    _model = State(
      initialValue: PutioProxyChooserModel(
        actions: PutioProxyChooserActions(runtime: runtime), preferences: preferences))
  }

  var body: some View {
    List {
      Group {
        if let choices = model.choices {
          routeSections(choices)
        } else if model.loadFailure != nil {
          PutioSettingsSection(PutioProxyChoices.summary) {
            PutioSettingsFailedRows(
              String(localized: "Couldn’t load proxies"),
              identifier: "proxy.failed",
              retryIdentifier: "proxy.retry"
            ) {
              Task { await model.loadRoutes() }
            }
          }
        } else {
          PutioSettingsSection(PutioProxyChoices.summary) {
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
      PutioProxyChoices.unavailableTitle,
      isPresented: $refusesRoute,
      message: PutioProxyChoices.unavailableMessage,
      actions: [
        PutioAlertAction(String(localized: "OK"), tier: .neutral, id: "proxy.unavailable-dismiss")
      ]
    )
    .task { await model.loadIfNeeded() }
  }

  @ViewBuilder private func routeSections(_ choices: PutioProxyChoices) -> some View {
    PutioSettingsSection(PutioProxyChoices.summary) {
      PutioChoiceList(
        selection: selection,
        options: [PutioProxyChoices.directRouteName] + choices.suggested.map(\.name)
      ) { name in
        guard name != PutioProxyChoices.directRouteName else {
          return PutioChoice(
            PutioProxyChoices.title(for: name), description: PutioProxyChoices.directDescription)
        }
        return PutioChoice(name, description: choices.description(for: name))
      }
      .disabled(!model.canSelect)
    }
    PutioSettingsSection {
      PutioChoiceList(selection: selection, options: choices.locations.map(\.name)) { name in
        PutioChoice(name)
      }
      .disabled(!model.canSelect)
    }
  }

  private var selection: Binding<String> {
    Binding(get: { model.selection }, set: { select($0) })
  }

  private func select(_ name: String) {
    Task {
      switch await model.select(name) {
      case .failed: saveFailures.report()
      case .unavailable: refusesRoute = true
      case .saved, .savedUnconfirmed, .skipped: break
      }
    }
  }
}
