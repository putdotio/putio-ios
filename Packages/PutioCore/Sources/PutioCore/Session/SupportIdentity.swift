/// Who the support messenger logs in as: the account id and put.io's
/// identity-verification hash of it. The hash proves the id to the vendor, so
/// it never prints.
public struct PutioSupportIdentity: Equatable, Sendable {
  public let userID: String
  public let userHash: String

  public init(userID: String, userHash: String) {
    self.userID = userID
    self.userHash = userHash
  }
}

extension PutioSupportIdentity: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: ["userID": userID, "userHash": "<redacted>"], displayStyle: .struct)
  }
}
