import SwiftUI
import Observation
import PutioSDK
#if canImport(UIKit)
import UIKit
#endif

/// Account screen built around the native `Form` + `Section` + `Toggle` +
/// `Picker` primitives. Sign out lives in the navigation toolbar. The
/// disk-usage progress sits in the form header.
struct AccountView: View {
    let container: AppContainer
    @Binding var path: [HomeDestination]
    @State private var viewModel: AccountViewModel
    @State private var confirmSignOut = false

    init(container: AppContainer, path: Binding<[HomeDestination]>) {
        self.container = container
        self._path = path
        _viewModel = State(initialValue: AccountViewModel(repository: container.account))
    }

    var body: some View {
        content
            .navigationTitle("Account")
            .toolbar { toolbarItems }
            .confirmationDialog(
                "Sign out of put.io?",
                isPresented: $confirmSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    container.authSession.signOut()
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear { viewModel.load() }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(role: .destructive) {
                confirmSignOut = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .ready(snapshot):
            Form {
                Section {
                    AccountHeader(account: snapshot.account)
                }

                Section("Playback") {
                    proxyPicker(snapshot: snapshot)

                    Toggle("Remember playback position", isOn: Binding(
                        get: { snapshot.settings.rememberVideoTime },
                        set: { viewModel.updateSettings(PutioAccountSettingsPatch(rememberVideoTime: $0)) }
                    ))

                    Toggle("Auto-select subtitles", isOn: Binding(
                        get: { !snapshot.settings.dontAutoSelectSubtitles },
                        set: { viewModel.updateSettings(PutioAccountSettingsPatch(dontAutoSelectSubtitles: !$0)) }
                    ))

                    Toggle("Hide subtitles by default", isOn: Binding(
                        get: { snapshot.settings.hideSubtitles },
                        set: { viewModel.updateSettings(PutioAccountSettingsPatch(hideSubtitles: $0)) }
                    ))

                    Toggle("Track watch history", isOn: Binding(
                        get: { snapshot.settings.historyEnabled },
                        set: { viewModel.updateSettings(PutioAccountSettingsPatch(historyEnabled: $0)) }
                    ))
                }

                Section("Storage") {
                    Toggle("Move deleted files to Trash", isOn: Binding(
                        get: { snapshot.settings.trashEnabled },
                        set: { viewModel.updateSettings(PutioAccountSettingsPatch(trashEnabled: $0)) }
                    ))

                    NavigationLink(value: HomeDestination(route: .trash)) {
                        Label("Manage your Trash", systemImage: "trash")
                    }
                }

                Section("App") {
                    LabeledContent("App version", value: appVersion)
                    LabeledContent("Device", value: deviceName)
                    LabeledContent("Operating system", value: osVersion)
                    NavigationLink(value: HomeDestination(route: .diagnostics)) {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                }
            }
        case let .failed(failure):
            PutErrorState(failure: failure)
        }
    }

    private func proxyPicker(snapshot: AccountViewModel.Snapshot) -> some View {
        Picker("Tunnel route", selection: Binding(
            get: { snapshot.settings.routeName },
            set: { newName in
                guard newName != snapshot.settings.routeName else { return }
                viewModel.updateSettings(PutioAccountSettingsPatch(tunnelRouteName: newName))
            }
        )) {
            ForEach(snapshot.routes, id: \.name) { route in
                Text(route.description.isEmpty ? route.name : route.description)
                    .tag(route.name)
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    private var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "Apple TV"
        #endif
    }

    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "tvOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

private struct AccountHeader: View {
    let account: PutioAccount

    var body: some View {
        HStack(spacing: PutSpacing.md) {
            AsyncImage(url: URL(string: account.avatarURL.replacingOccurrences(of: "s=50", with: "s=200"))) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: PutSpacing.xs) {
                Text(account.username)
                    .font(.title2)
                    .foregroundStyle(.primary)
                ProgressView(value: usageFraction)
                    .tint(Color.put.yellowSolid)
                    .frame(maxWidth: 480)
                Text(usageString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, PutSpacing.xs)
    }

    private var usageFraction: Double {
        let size = max(account.disk.size, 1)
        return min(1, Double(account.disk.used) / Double(size))
    }

    private var usageString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let used = formatter.string(fromByteCount: account.disk.used)
        let total = formatter.string(fromByteCount: account.disk.size)
        return "\(used) of \(total) used"
    }
}
