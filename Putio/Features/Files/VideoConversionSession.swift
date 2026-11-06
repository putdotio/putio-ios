import Foundation
import PutioSDK

protocol VideoConversionSessionDelegate: AnyObject {
    func videoConversionSessionStateChanged(_ session: VideoConversionSession)
}

final class VideoConversionSession {
    struct Progress {
        let status: PutioMp4Conversion.Status
        let percentDone: Float
    }

    enum Failure {
        case start(PutioSDKError)
        case status(PutioSDKError)
        case convertedFile(PutioSDKError)
        case conversion(PutioMp4Conversion.Status)
    }

    enum State {
        case idle
        case starting
        case converting(Progress)
        case fetchingConvertedFile
        case finished(PutioFile)
        case failed(Failure)
        case cancelled
    }

    typealias StartRequest = (Int, @escaping (Result<Void, PutioSDKError>) -> Void) -> Void
    typealias StatusRequest = (Int, @escaping (Result<Progress, PutioSDKError>) -> Void) -> Void
    typealias FileRequest = (Int, @escaping (Result<PutioFile, PutioSDKError>) -> Void) -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void

    static let pollInterval: TimeInterval = 3
    static let maxStatusRetries = 3

    weak var delegate: VideoConversionSessionDelegate?

    private(set) var state: State = .idle {
        didSet {
            delegate?.videoConversionSessionStateChanged(self)
        }
    }

    private let fileID: Int
    private let startRequest: StartRequest
    private let statusRequest: StatusRequest
    private let fileRequest: FileRequest
    private let schedule: Schedule
    private var generation = 0
    private var statusFailures = 0
    private var cancelScheduledPoll: (() -> Void)?

    init(
        fileID: Int,
        startRequest: @escaping StartRequest = { fileID, completion in
            api.startMp4Conversion(fileID: fileID) { result in
                completion(result.map { _ in () })
            }
        },
        statusRequest: @escaping StatusRequest = { fileID, completion in
            api.getMp4ConversionStatus(fileID: fileID) { result in
                completion(result.map { Progress(status: $0.status, percentDone: $0.percentDone) })
            }
        },
        fileRequest: @escaping FileRequest = { fileID, completion in
            api.getFile(fileID: fileID, completion)
        },
        schedule: @escaping Schedule = { delay, work in
            let item = DispatchWorkItem(block: work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item.cancel
        }
    ) {
        self.fileID = fileID
        self.startRequest = startRequest
        self.statusRequest = statusRequest
        self.fileRequest = fileRequest
        self.schedule = schedule
    }

    var isActive: Bool {
        switch state {
        case .starting, .converting, .fetchingConvertedFile:
            return true
        case .idle, .finished, .failed, .cancelled:
            return false
        }
    }

    func start() {
        invalidatePendingWork()
        statusFailures = 0
        state = .starting

        let generation = self.generation
        startRequest(fileID) { [weak self] result in
            guard let self, self.isCurrent(generation) else { return }

            switch result {
            case .success:
                self.checkStatus(generation: generation)
            case .failure(let error):
                self.state = .failed(.start(error))
            }
        }
    }

    func cancel() {
        invalidatePendingWork()
        guard isActive else { return }
        state = .cancelled
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    private func invalidatePendingWork() {
        generation += 1
        cancelScheduledPoll?()
        cancelScheduledPoll = nil
    }

    private func checkStatus(generation: Int) {
        statusRequest(fileID) { [weak self] result in
            guard let self, self.isCurrent(generation) else { return }

            switch result {
            case .success(let progress):
                self.statusFailures = 0
                self.handle(progress, generation: generation)

            case .failure(let error):
                self.statusFailures += 1
                if self.statusFailures > Self.maxStatusRetries {
                    self.state = .failed(.status(error))
                } else {
                    self.schedulePoll(generation: generation)
                }
            }
        }
    }

    private func handle(_ progress: Progress, generation: Int) {
        switch progress.status {
        case .completed:
            state = .fetchingConvertedFile
            fetchConvertedFile(generation: generation)

        case .error, .notAvailable:
            state = .failed(.conversion(progress.status))

        default:
            state = .converting(progress)
            schedulePoll(generation: generation)
        }
    }

    private func schedulePoll(generation: Int) {
        cancelScheduledPoll = schedule(Self.pollInterval) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.cancelScheduledPoll = nil
            self.checkStatus(generation: generation)
        }
    }

    private func fetchConvertedFile(generation: Int) {
        fileRequest(fileID) { [weak self] result in
            guard let self, self.isCurrent(generation) else { return }

            switch result {
            case .success(let file):
                self.state = .finished(file)
            case .failure(let error):
                self.state = .failed(.convertedFile(error))
            }
        }
    }
}
