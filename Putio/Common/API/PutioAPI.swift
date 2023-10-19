import Foundation
import PutioAPI

let api = PutioAPI(config: PutioAPIConfig(
    clientID: PUTIOKIT_CLIENT_ID,
    clientSecret: PUTIOKIT_CLIENT_SECRET,
    clientName: UIDevice.current.name)
)
