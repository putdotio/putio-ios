import Foundation
import PutioSDK
#if canImport(UIKit)
import UIKit
#endif

/// Builds the singleton `PutioSDK` instance for the tvOS target. The tvOS app
/// uses the `2951` client id by default but accepts a build-time override via
/// `PUTIO_OAUTH_CLIENT_ID` in the Info.plist (see `PutioTVConstants`).
enum PutioClient {
    static func make() -> PutioSDK {
        let clientName: String
        #if canImport(UIKit)
        clientName = UIDevice.current.name
        #else
        clientName = "Apple TV"
        #endif

        let config = PutioSDKConfig(
            clientID: PutioTV.clientID,
            clientName: clientName
        )

        return PutioSDK(config: config)
    }
}
