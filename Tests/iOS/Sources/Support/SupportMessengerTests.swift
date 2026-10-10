import PutioCore
import XCTest

@testable import Putio

@MainActor
final class SupportMessengerTests: XCTestCase {
  private let configuration = IntercomConfiguration(info: [
    "PUTIO_INTERCOM_ENABLED": "YES", "PUTIO_INTERCOM_API_KEY": "ios_sdk-synthetic",
    "PUTIO_INTERCOM_APP_ID": "synthetic",
  ])
  private let identity = PutioSupportIdentity(userID: "1001", userHash: "synthetic-hash")

  func testStartsOnlyAfterSignInAndLogsOutWhenTheSessionEnds() throws {
    let client = RecordingSupportClient()
    let messenger = PutioSupportMessenger(configuration: configuration, client: client)

    for state in [PutioSessionState.unknown, .signedOut(nil), .authenticating] {
      messenger.sessionDidChange(state, identity: nil)
    }
    XCTAssertEqual(client.calls, [], "Intercom started before sign-in")

    messenger.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    messenger.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    XCTAssertEqual(client.calls, [.start, .logIn("1001", "synthetic-hash")])

    var opened: [URL] = []
    messenger.contactSupport { opened.append($0) }
    XCTAssertEqual(client.calls.last, .present)
    XCTAssertEqual(opened, [])

    messenger.sessionDidChange(.signingOut, identity: nil)
    messenger.sessionDidChange(.signedOut(.userSignedOut), identity: nil)
    XCTAssertEqual(client.calls.suffix(1), [.logOut])

    let other = PutioSupportIdentity(userID: "2002", userHash: "other-hash")
    messenger.sessionDidChange(.signedIn(Self.account(id: 2002)), identity: other)
    XCTAssertEqual(client.calls.suffix(1), [.logIn("2002", "other-hash")], "started twice")
  }

  func testFallsBackToEmailWithoutKeysHashOrASuccessfulLogin() {
    var opened: [URL] = []
    let switchedOff = RecordingSupportClient()
    let off = PutioSupportMessenger(configuration: nil, client: switchedOff)
    off.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    off.contactSupport { opened.append($0) }
    XCTAssertEqual(switchedOff.calls, [])

    let unverified = RecordingSupportClient()
    let noHash = PutioSupportMessenger(configuration: configuration, client: unverified)
    noHash.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: nil)
    noHash.contactSupport { opened.append($0) }
    XCTAssertEqual(unverified.calls, [])

    let failing = RecordingSupportClient(logInSucceeds: false)
    let rejected = PutioSupportMessenger(configuration: configuration, client: failing)
    rejected.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    rejected.contactSupport { opened.append($0) }
    XCTAssertFalse(failing.calls.contains(.present))

    XCTAssertEqual(opened, Array(repeating: URL(string: "mailto:support@put.io")!, count: 3))
  }

  func testKillSwitchAndMissingKeysDisableTheMessenger() {
    let complete: [String: Any] = [
      "PUTIO_INTERCOM_ENABLED": "YES", "PUTIO_INTERCOM_API_KEY": "k", "PUTIO_INTERCOM_APP_ID": "a",
    ]
    XCTAssertEqual(IntercomConfiguration(info: complete)?.appID, "a")
    for (key, value) in [
      ("PUTIO_INTERCOM_ENABLED", "NO"), ("PUTIO_INTERCOM_API_KEY", ""),
      ("PUTIO_INTERCOM_APP_ID", "$(PUTIO_INTERCOM_APP_ID)"),
    ] {
      XCTAssertNil(IntercomConfiguration(info: complete.merging([key: value]) { $1 }), key)
    }
    XCTAssertNil(IntercomConfiguration(bundle: .main), "a checked-in build must not carry keys")
  }

  private static func account(id: Int) -> PutioAccountSnapshot {
    PutioAccountSnapshot(
      id: id, username: "fixture", email: "fixture@example.invalid", suggestNextVideo: false,
      rememberVideoTime: false, defaultSort: nil, historyEnabled: true, trashEnabled: true,
      storage: .init(availableBytes: 100, totalBytes: 200, usedBytes: 100))
  }
}

@MainActor
private final class RecordingSupportClient: SupportMessengerClient {
  enum Call: Equatable {
    case start
    case logIn(String, String)
    case logOut
    case present
  }

  private(set) var calls: [Call] = []
  private let logInSucceeds: Bool

  init(logInSucceeds: Bool = true) {
    self.logInSucceeds = logInSucceeds
  }

  func start(_ configuration: IntercomConfiguration) { calls.append(.start) }

  func logIn(_ identity: PutioSupportIdentity, completion: @escaping @MainActor (Bool) -> Void) {
    calls.append(.logIn(identity.userID, identity.userHash))
    completion(logInSucceeds)
  }

  func logOut() { calls.append(.logOut) }

  func present() { calls.append(.present) }
}
