import Foundation
import Observation
import PutioSDK

/// Single dependency container for the tvOS app. View-models and features pick
/// up the wiring they need from here.
///
/// Created once in `PutioTVApp` and never replaced.
@MainActor
final class AppContainer {
    let api: PutioSDK
    let tokenStore: TokenStoring
    let authSession: AuthSession
    let files: FilesRepositoryProtocol
    let account: AccountRepositoryProtocol
    let history: HistoryRepositoryProtocol
    let trash: TrashRepositoryProtocol
    let media: MediaRepositoryProtocol
    let playback: PlaybackSession

    init() {
        let api = PutioClient.make()
        self.api = api
        let tokenStore = KeychainTokenStore()
        self.tokenStore = tokenStore

        self.files = FilesRepository(api: api)
        self.account = AccountRepository(api: api)
        self.history = HistoryRepository(api: api)
        self.trash = TrashRepository(api: api)
        let media = MediaRepository(api: api)
        self.media = media

        let auth = AuthSession(
            api: api,
            tokenStore: tokenStore,
            deviceCodeService: DeviceCodeService(api: api)
        )
        self.authSession = auth

        self.playback = PlaybackSession(
            api: api,
            files: FilesRepository(api: api),
            media: media,
            tokenProvider: { [weak auth] in auth?.state.token }
        )
    }
}
