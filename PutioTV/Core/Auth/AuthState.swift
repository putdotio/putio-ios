import Foundation

/// Discriminated union for the device-code auth flow. Mirrors the React
/// Native `useAuthCodeAuthenticator` hook from
/// `putio-web/apps/tv-native/src/features/auth/...`. See
/// `.patterns/state-machines.md`.
enum AuthState: Equatable {
    case idle
    case creatingCode
    case awaitingLink(code: String, qrCodeURL: URL?)
    case verifyingToken(token: String)
    case linked(token: String, account: AuthLinkedAccount)
    case failed(LocalizedFailure)

    var token: String? {
        switch self {
        case let .linked(token, _): return token
        case let .verifyingToken(token): return token
        default: return nil
        }
    }
}

struct AuthLinkedAccount: Equatable, Sendable {
    let userID: Int
    let tokenID: Int?
}
