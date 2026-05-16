import Foundation
import Observation
import PutioSDK

@MainActor
@Observable
final class PlaybackSession {
    private(set) var state: PlaybackState = .idle

    private let api: PutioSDK
    private let files: FilesRepositoryProtocol
    private let media: MediaRepositoryProtocol
    private let tokenProvider: @MainActor () -> String?

    private var conversionTask: Task<Void, Never>?
    private var writeBackTask: Task<Void, Never>?
    private var lastWriteBack: Date = .distantPast

    init(
        api: PutioSDK,
        files: FilesRepositoryProtocol,
        media: MediaRepositoryProtocol,
        tokenProvider: @escaping @MainActor () -> String?
    ) {
        self.api = api
        self.files = files
        self.media = media
        self.tokenProvider = tokenProvider
    }

    func open(fileID: Int) {
        cancelTasks()
        state = .preparing(fileID: fileID)

        Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await files.details(fileID: fileID)
                guard let token = tokenProvider(), !token.isEmpty else {
                    state = .failed(LocalizedFailure(message: "Signed out", recovery: nil, retry: nil))
                    return
                }

                switch PlaybackSourceResolver.decide(for: file, token: token) {
                case let .ready(source):
                    let resumeAt = file.startFrom
                    if resumeAt > 0 {
                        state = .resumePrompt(file: file, source: source, resumeAt: resumeAt)
                    } else {
                        state = .playing(file: file, source: source, startAt: 0)
                    }
                case .needsConversion:
                    state = .converting(file: file, progress: 0)
                    pollConversion(for: file)
                case .unsupported:
                    state = .unsupported(file: file)
                }
            } catch {
                state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.open(fileID: fileID) }))
            }
        }
    }

    func startFromBeginning() {
        guard case let .resumePrompt(file, source, _) = state else { return }
        state = .playing(file: file, source: source, startAt: 0)
    }

    func resume() {
        guard case let .resumePrompt(file, source, resumeAt) = state else { return }
        state = .playing(file: file, source: source, startAt: resumeAt)
    }

    /// Throttled progress write-back. Mirrors the RN tvOS player's
    /// `setStartFrom` cadence (~10s).
    func reportProgress(seconds: Int) {
        guard case let .playing(file, _, _) = state else { return }
        let now = Date.now
        guard now.timeIntervalSince(lastWriteBack) >= 10 else { return }
        lastWriteBack = now

        writeBackTask?.cancel()
        writeBackTask = Task { [weak self] in
            guard let self else { return }
            try? await media.setStartFrom(fileID: file.id, seconds: seconds)
        }
    }

    func finish(durationSeconds: Int) {
        guard case let .playing(file, _, _) = state else { return }
        state = .finished(file: file, durationSeconds: durationSeconds)
        Task { [media] in
            try? await media.resetStartFrom(fileID: file.id)
        }
    }

    func reset() {
        cancelTasks()
        state = .idle
    }

    private func cancelTasks() {
        conversionTask?.cancel()
        conversionTask = nil
        writeBackTask?.cancel()
        writeBackTask = nil
    }

    private func pollConversion(for file: PutioFile) {
        conversionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let status = try await files.conversionStatus(fileID: file.id)
                    state = .converting(file: file, progress: status.percentDone)
                    if status.status == .completed {
                        open(fileID: file.id)
                        return
                    }
                    if status.status == .error {
                        state = .failed(LocalizedFailure(
                            message: "Conversion failed.",
                            recovery: "put.io couldn't convert this video. Try again later.",
                            retry: { [weak self] in self?.open(fileID: file.id) }
                        ))
                        return
                    }
                    try await Task.sleep(for: .seconds(5))
                } catch is CancellationError {
                    return
                } catch {
                    state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.open(fileID: file.id) }))
                    return
                }
            }
        }
    }
}
