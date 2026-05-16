import SwiftUI
import PutioSDK

/// Orchestrates the `PlaybackSession` state machine and renders the right
/// surface for each state: resume prompt, conversion progress, unsupported,
/// the system player, or a recoverable failure.
struct PlayerView: View {
    let container: AppContainer
    let fileID: Int

    var body: some View {
        let session = container.playback

        ZStack {
            Color.black.ignoresSafeArea()

            switch session.state {
            case .idle, .preparing:
                PutLoadingState(title: "Preparing video")
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
                PutLoadingState(title: "Done")
            case let .failed(failure):
                PutErrorState(failure: failure)
            }
        }
        .onAppear { session.open(fileID: fileID) }
        .onDisappear { session.reset() }
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(.hidden)
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
            onProgress: { seconds in container.playback.reportProgress(seconds: seconds) },
            onFinish: { seconds in container.playback.finish(durationSeconds: seconds) },
            onError: { _ in
                container.playback.reset()
            }
        )
        .ignoresSafeArea()
    }
}

struct ResumePromptView: View {
    let file: PutioFile
    let resumeAt: Int
    let onResume: () -> Void
    let onStartOver: () -> Void

    var body: some View {
        VStack(spacing: PutSpacing.lg) {
            Text(file.name)
                .font(.put.label)
                .foregroundStyle(Color.put.text)
                .multilineTextAlignment(.center)

            VStack(spacing: PutSpacing.sm) {
                Button(action: onResume) {
                    Label(
                        "Continue playing from \(formattedResumeOffset)",
                        systemImage: "play.fill"
                    )
                    .font(.put.body)
                    .padding(.horizontal, PutSpacing.lg)
                    .padding(.vertical, PutSpacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.put.yellowSolid)

                Button(action: onStartOver) {
                    Label("Start from the beginning", systemImage: "backward.end")
                        .font(.put.body)
                        .padding(.horizontal, PutSpacing.lg)
                        .padding(.vertical, PutSpacing.sm)
                }
                .buttonStyle(.bordered)
                .tint(Color.put.text)
            }
        }
        .padding(PutSpacing.xxl)
    }

    private var formattedResumeOffset: String {
        let minutes = resumeAt / 60
        let seconds = resumeAt % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct ConversionStatusView: View {
    let file: PutioFile
    let progress: Float

    var body: some View {
        VStack(spacing: PutSpacing.lg) {
            Text(file.name)
                .font(.put.label)
                .foregroundStyle(Color.put.text)
                .multilineTextAlignment(.center)
            ProgressView(value: max(0, min(1, Double(progress))))
                .controlSize(.large)
                .frame(maxWidth: 480)
            Text("Converting to a TV-friendly format…")
                .font(.put.body)
                .foregroundStyle(Color.put.textSecondary)
        }
        .padding(PutSpacing.xxl)
    }
}

struct UnsupportedFileView: View {
    let file: PutioFile

    var body: some View {
        PutEmptyState(
            icon: "file",
            title: "Unsupported file type",
            message: "Open \(file.name) in put.io on the web or a mobile app to view it."
        )
    }
}
