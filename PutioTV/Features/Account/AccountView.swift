import SwiftUI
import Observation
import PutioSDK
#if canImport(UIKit)
import UIKit
#endif

/// Account screen. Matches `09-account-playback-top`, `10-account-proxy-picker`,
/// `12-account-storage`, and `14-account-app-device`. Android-only Playback
/// type and buffer-size rows are deliberately omitted (tvOS forces HLS in
/// `PlaybackSourceResolver`).
struct AccountView: View {
    let container: AppContainer
    @Binding var path: [HomeDestination]
    @State private var viewModel: AccountViewModel

    init(container: AppContainer, path: Binding<[HomeDestination]>) {
        self.container = container
        self._path = path
        _viewModel = State(initialValue: AccountViewModel(repository: container.account))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PutScreenHeader {
                Text("Account")
            } trailing: {
                Button {
                    container.authSession.signOut()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .tint(Color.put.textPrimary)
            }

            content
        }
        .background(Color.put.surface)
        .onAppear { viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            PutLoadingState()
        case let .ready(snapshot):
            ScrollView {
                VStack(alignment: .leading, spacing: PutSpacing.lg) {
                    header(snapshot: snapshot)

                    section("Playback settings") {
                        proxyRow(snapshot: snapshot)

                        toggleRow(
                            icon: "rotate-ccw",
                            title: "Remember where I left off",
                            isOn: snapshot.settings.rememberVideoTime
                        ) { isOn in
                            viewModel.updateSettings(
                                PutioAccountSettingsPatch(rememberVideoTime: isOn)
                            )
                        }

                        toggleRow(
                            icon: "subtitles",
                            title: "Auto-select subtitles",
                            isOn: !snapshot.settings.dontAutoSelectSubtitles
                        ) { isOn in
                            viewModel.updateSettings(
                                PutioAccountSettingsPatch(dontAutoSelectSubtitles: !isOn)
                            )
                        }

                        toggleRow(
                            icon: "eye",
                            title: "Hide subtitles by default",
                            isOn: snapshot.settings.hideSubtitles
                        ) { isOn in
                            viewModel.updateSettings(
                                PutioAccountSettingsPatch(hideSubtitles: isOn)
                            )
                        }

                        toggleRow(
                            icon: "history",
                            title: "Track watch history",
                            isOn: snapshot.settings.historyEnabled
                        ) { isOn in
                            viewModel.updateSettings(
                                PutioAccountSettingsPatch(historyEnabled: isOn)
                            )
                        }
                    }

                    section("Storage settings") {
                        toggleRow(
                            icon: "trash",
                            title: "Move deleted files to Trash",
                            isOn: snapshot.settings.trashEnabled
                        ) { isOn in
                            viewModel.updateSettings(
                                PutioAccountSettingsPatch(trashEnabled: isOn)
                            )
                        }

                        Button {
                            path.append(HomeDestination(route: .trash))
                        } label: {
                            PutListRow(icon: "trash", title: "Manage your trash")
                        }
                        .buttonStyle(PutFocusableRowStyle())

                        storageRow(snapshot: snapshot)
                    }

                    section("App and device information") {
                        infoRow(icon: "monitor", title: "App", value: appVersion)
                        infoRow(icon: "smartphone", title: "Device", value: deviceName)
                        infoRow(icon: "tv", title: "OS", value: osVersion)
                        Button {
                            path.append(HomeDestination(route: .diagnostics))
                        } label: {
                            PutListRow(icon: "wrench", title: "Diagnostics")
                        }
                        .buttonStyle(PutFocusableRowStyle())
                    }
                }
                .padding(.horizontal, PutSpacing.xl)
                .padding(.bottom, PutSpacing.xl)
            }
        case let .failed(failure):
            PutErrorState(failure: failure)
        }
    }

    private func header(snapshot: AccountViewModel.Snapshot) -> some View {
        HStack(spacing: PutSpacing.md) {
            AsyncImage(url: URL(string: snapshot.account.avatarURL.replacingOccurrences(of: "s=50", with: "s=200"))) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    Color.put.surfaceElevated
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: PutSpacing.xs) {
                Text(snapshot.account.username)
                    .font(.put.title)
                    .foregroundStyle(Color.put.textPrimary)
                let used = snapshot.account.disk.used
                let total = snapshot.account.disk.size
                Text(usageString(used: used, total: total))
                    .font(.put.secondary)
                    .foregroundStyle(Color.put.textSecondary)
            }
            Spacer()
        }
    }

    private func proxyRow(snapshot: AccountViewModel.Snapshot) -> some View {
        Menu {
            ForEach(snapshot.routes, id: \.name) { route in
                Button(route.description.isEmpty ? route.name : route.description) {
                    viewModel.updateSettings(
                        PutioAccountSettingsPatch(tunnelRouteName: route.name)
                    )
                }
            }
        } label: {
            PutListRow(
                icon: "network",
                title: "Tunnel route",
                subtitle: snapshot.settings.routeName,
                trailing: "Change"
            )
        }
        .buttonStyle(PutFocusableRowStyle())
    }

    private func toggleRow(
        icon: String,
        title: String,
        isOn: Bool,
        action: @escaping (Bool) -> Void
    ) -> some View {
        Button {
            action(!isOn)
        } label: {
            PutListRow(
                icon: icon,
                title: title,
                trailing: isOn ? "On" : "Off"
            )
        }
        .buttonStyle(PutFocusableRowStyle())
    }

    private func storageRow(snapshot: AccountViewModel.Snapshot) -> some View {
        let used = snapshot.account.disk.used
        let total = snapshot.account.disk.size
        return PutListRow(
            icon: "package-open",
            title: "Storage",
            subtitle: usageString(used: used, total: total),
            trailing: ""
        )
        .padding(.horizontal, PutSpacing.md)
        .padding(.vertical, PutSpacing.xs)
    }

    private func usageString(used: Int64, total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let usedString = formatter.string(fromByteCount: used)
        let totalString = formatter.string(fromByteCount: total)
        return "\(usedString) of \(totalString) used"
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        PutListRow(icon: icon, title: title, subtitle: value, trailing: "")
            .padding(.horizontal, PutSpacing.md)
            .padding(.vertical, PutSpacing.xs)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PutSpacing.xs) {
            Text(title)
                .font(.put.headline)
                .foregroundStyle(Color.put.textSecondary)
                .padding(.horizontal, PutSpacing.md)
                .padding(.top, PutSpacing.md)
            content()
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
