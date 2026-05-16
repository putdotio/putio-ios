import SwiftUI
import PutioSDK

/// Orchestrates the `PlaybackSession` state machine and renders the right
/// surface for each state: resume prompt, conversion progress, unsupported,
/// the system player, or a recoverable failure.
struct PlayerView: View {
    let container: AppContainer
    let fileID: Int
    @State private var subtitlePreference: SystemPlayerView.SubtitlePreference = .systemDefault

    var body: some View {
        let session = container.playback

        ZStack {
            Color.black.ignoresSafeArea()

            switch session.state {
            case .idle, .preparing:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            case let .resumePrompt(file, _, resumeAt):
                ResumePromptView(file: file, resumeAt: resumeAt) {
                    session.resume()
                } onStartOver: {
                    session.startFromBeginning()
                }
            case let .converting(file, progress):
                ConversionStatusView(file: file, progress: progress)
            case let .unsupported(file):
                UnsupportedFileView(file: file)
            case let .playing(_, source, startAt):
                playerSurface(source: source, startAt: startAt)
            case .finished:
                Color.clear
            case let .failed(failure):
                PlayerErrorView(failure: failure) {
                    container.player.dismiss()
                }
            }
        }
        .onAppear { session.open(fileID: fileID) }
        // No `session.reset()` here — `PlayerPresenter.dismiss()` owns the
        // cleanup path so a single dismissal isn't fighting the cover's
        // own teardown.
        .task { await loadSubtitlePreference() }
    }

    private func loadSubtitlePreference() async {
        do {
            let settings = try await container.account.settings()
            subtitlePreference = SystemPlayerView.SubtitlePreference(
                hideSubtitles: settings.hideSubtitles,
                dontAutoSelect: settings.dontAutoSelectSubtitles
            )
        } catch {
            subtitlePreference = .systemDefault
        }
    }

    private func playerSurface(source: PlaybackSourceResolver.Source, startAt: Int) -> some View {
        let url: URL = {
            switch source {
            case let .hls(url): return url
            case let .mp4(url): return url
            }
        }()

        return SystemPlayerView(
            url: url,
            startAt: startAt,
            subtitlePreference: subtitlePreference,
            onProgress: { seconds in container.playback.reportProgress(seconds: seconds) },
            onFinish: { seconds in container.playback.finish(durationSeconds: seconds) },
            onError: { error in container.playback.fail(with: error) }
        )
        .ignoresSafeArea()
    }
}

struct ResumePromptView: View {
    let file: PutioFile
    let resumeAt: Int
    let onResume: () -> Void
    let onStartOver: () -> Void

    @FocusState private var resumeFocused: Bool

    var body: some View {
        VStack(spacing: 48) {
            Text(file.name)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 128)

            HStack(spacing: 32) {
                Button {
                    onResume()
                } label: {
                    Label("Resume from \(formattedResumeOffset)", systemImage: "play.fill")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.put.yellowSolid)
                .foregroundStyle(.black)
                .focused($resumeFocused)

                Button {
                    onStartOver()
                } label: {
                    Label("Start from beginning", systemImage: "backward.end.fill")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.white)
            }
        }
        .onAppear { resumeFocused = true }
    }

    private var formattedResumeOffset: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.allowedUnits = resumeAt >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: TimeInterval(resumeAt)) ?? "0:00"
    }
}

struct ConversionStatusView: View {
    let file: PutioFile
    let progress: Float

    var body: some View {
        VStack(spacing: 32) {
            Text(file.name)
                .font(.title)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            ProgressView(value: max(0, min(1, Double(progress))))
                .controlSize(.large)
                .frame(maxWidth: 480)
                .tint(.accentColor)
            Text("Converting to a TV-friendly format…")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(128)
    }
}

struct UnsupportedFileView: View {
    let file: PutioFile

    var body: some View {
        ContentUnavailableView(
            "Unsupported file type",
            systemImage: "questionmark.video",
            description: Text("We currently only support video files in this app (for now).")
        )
    }
}

private struct PlayerErrorView: View {
    let failure: LocalizedFailure
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            ContentUnavailableView(
                failure.message,
                systemImage: "exclamationmark.triangle",
                description: failure.recovery.map(Text.init)
            )
            Button("Done") { onDismiss() }
                .buttonStyle(.bordered)
        }
    }
}
