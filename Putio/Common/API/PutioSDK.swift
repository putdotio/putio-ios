import Foundation
import PutioSDK

let api = PutioSDK(config: PutioSDKConfig(
    clientID: PUTIOKIT_CLIENT_ID,
    clientName: UIDevice.current.name)
)
