import Foundation
import Observation
import PutioSDK

/// Long-lived session object. Owns the token, drives the auth state machine,
/// and exposes the linked account id to the rest of the app via `state`.
///
/// SwiftUI views observe this object through `@Bindable` / `@Environment`.
@MainActor
@Observable
final class AuthSession {
    private(set) var state: AuthState = .idle

    private let api: PutioSDK
    private let tokenStore: TokenStoring
    private let deviceCodeService: DeviceCodeServicing
    private var activeTask: Task<Void, Never>?

    init(api: PutioSDK, tokenStore: TokenStoring, deviceCodeService: DeviceCodeServicing) {
        self.api = api
        self.tokenStore = tokenStore
        self.deviceCodeService = deviceCodeService
    }

    func restore() {
        #if DEBUG
        // DEBUG hook: lets `xcrun simctl launch ... --setenv PUTIO_INJECT_TOKEN=...`
        // drive the simulator straight into the linked surfaces during parity
        // capture without OCR'ing the device code from the auth screen.
        if let injected = ProcessInfo.processInfo.environment["PUTIO_INJECT_TOKEN"],
           !injected.isEmpty {
            try? tokenStore.save(injected)
            validate(token: injected)
            return
        }
        #endif
        guard let token = tokenStore.load(), !token.isEmpty else { return }
        validate(token: token)
    }

    func start() {
        cancelActive()
        state = .creatingCode

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let auth = try await deviceCodeService.createCode()
                guard !Task.isCancelled else { return }
                state = .awaitingLink(code: auth.code, qrCodeURL: auth.qrCodeURL)

                let token = try await deviceCodeService.awaitLinkedToken(forCode: auth.code)
                guard !Task.isCancelled else { return }
                validate(token: token)
            } catch is CancellationError {
                // Restart triggered: nothing to do, state will be overwritten.
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.start() }))
            }
        }
    }

    func cancel() {
        cancelActive()
        state = .idle
    }

    func signOut() {
        cancelActive()
        Task { try? await api.logout() }
        try? tokenStore.clear()
        api.config.token = ""
        state = .idle
    }

    private func cancelActive() {
        activeTask?.cancel()
        activeTask = nil
    }

    private func validate(token: String) {
        cancelActive()
        state = .verifyingToken(token: token)

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await api.validateToken(token: token)
                guard result.result, let userID = result.userID else {
                    try? tokenStore.clear()
                    state = .failed(LocalizedFailure(
                        message: "Token validation failed",
                        recovery: "Get a new code and try linking the device again.",
                        retry: { [weak self] in self?.start() }
                    ))
                    return
                }

                try tokenStore.save(token)
                api.config.token = token
                state = .linked(token: token, account: AuthLinkedAccount(userID: userID, tokenID: result.tokenID))
            } catch is CancellationError {
                return
            } catch {
                state = .failed(ErrorMapping.localize(error, retry: { [weak self] in self?.start() }))
            }
        }
    }
}
