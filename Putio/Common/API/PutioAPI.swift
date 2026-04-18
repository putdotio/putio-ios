import Foundation
import PutioAPI

let api = PutioAPI(config: PutioAPIConfig(
    clientID: PUTIOKIT_CLIENT_ID,
    clientName: UIDevice.current.name)
)
