import Foundation
import GoogleCast

enum CastReceiver: Equatable {
    case defaultMedia
    case putio

    static let namespace = "urn:x-cast:io.put.cast"

    init(usesPutioReceiver: Bool) {
        self = usesPutioReceiver ? .putio : .defaultMedia
    }

    init?(applicationID: String?) {
        guard let applicationID else { return nil }
        if applicationID == PUTIO_CAST_RECEIVER_APP_ID {
            self = .putio
        } else if applicationID == CHROMECAST_RECEIVER_APP_ID {
            self = .defaultMedia
        } else {
            return nil
        }
    }

    var applicationID: String {
        switch self {
        case .defaultMedia: return CHROMECAST_RECEIVER_APP_ID
        case .putio: return PUTIO_CAST_RECEIVER_APP_ID
        }
    }
}

struct PutioCastLoad: Equatable {
    enum Method: String {
        case hls, file
    }

    let fileID: Int
    let method: Method
    let position: Int
    let token: String
    let maxSubtitleCount: Int?

    init(fileID: Int, method: Method, position: Int, token: String, hidesSubtitles: Bool) {
        self.fileID = fileID
        self.method = method
        self.position = max(0, position)
        self.token = token
        self.maxSubtitleCount = hidesSubtitles ? 0 : nil
    }

    var customData: [String: Any] {
        var data: [String: Any] = [
            "fileId": fileID,
            "method": method.rawValue,
            "position": position,
            "token": token
        ]
        if let maxSubtitleCount {
            data["maxSubtitleCount"] = maxSubtitleCount
        }
        return data
    }
}

enum PutioReceiverStatus: Equatable {
    enum Reason: String, Error {
        case missingFile = "missing_file"
        case missingToken = "missing_token"
        case invalidCustomData = "invalid_custom_data"
        case invalidToken = "invalid_token"
        case fileNotFound = "file_not_found"
        case streamFailed = "stream_failed"

        var playbackError: AnalyticsEvent.PlaybackError {
            switch self {
            case .missingToken, .invalidToken, .fileNotFound: return .source
            case .streamFailed: return .media
            case .missingFile, .invalidCustomData: return .unknown
            }
        }
    }

    case idle
    case loading(fileID: Int?)
    case loaded(fileID: Int?)
    case failed(fileID: Int?, reason: Reason)

    private struct Message: Decodable {
        struct State: Decodable {
            let status: String
            let fileId: Int?
            let reason: String?
        }

        let type: String
        let state: State
    }

    init?(message: String) {
        guard let data = message.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Message.self, from: data),
              decoded.type == "STATUS" else { return nil }
        let state = decoded.state
        switch state.status {
        case "idle": self = .idle
        case "loading": self = .loading(fileID: state.fileId)
        case "loaded": self = .loaded(fileID: state.fileId)
        case "failed":
            guard let reason = state.reason.flatMap(Reason.init(rawValue:)) else { return nil }
            self = .failed(fileID: state.fileId, reason: reason)
        default: return nil
        }
    }
}

final class PutioCastChannel: GCKCastChannel {
    var onStatus: ((PutioReceiverStatus) -> Void)?

    override func didConnect() {
        super.didConnect()
        requestStatus()
    }

    override func didReceiveTextMessage(_ message: String) {
        guard let status = PutioReceiverStatus(message: message) else { return }
        onStatus?(status)
    }

    func requestStatus() {
        sendTextMessage(#"{"type":"GET_STATUS"}"#, error: nil)
    }
}
