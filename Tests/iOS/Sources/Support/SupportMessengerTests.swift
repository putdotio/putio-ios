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
  private let email = URL(string: "mailto:support@put.io")!

  func testStartsOnlyAfterSignInAndLogsOutWhenTheSessionEnds() throws {
    let client = RecordingSupportClient()
    let messenger = try makeMessenger(client)

    for state in [PutioSessionState.unknown, .signedOut(nil), .authenticating] {
      messenger.sessionDidChange(state, identity: nil)
    }
    XCTAssertEqual(client.calls, [], "Intercom started before sign-in")

    messenger.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    messenger.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    XCTAssertEqual(
      client.calls, [.start, .logIn("1001", "synthetic-hash"), .registerForRemoteNotifications])

    var opened: [URL] = []
    messenger.contactSupport { opened.append($0) }
    XCTAssertEqual(client.calls.last, .present)
    XCTAssertEqual(opened, [])

    messenger.sessionDidChange(.signingOut, identity: nil)
    messenger.sessionDidChange(.signedOut(.userSignedOut), identity: nil)
    XCTAssertEqual(client.calls.suffix(1), [.logOut])

    let other = PutioSupportIdentity(userID: "2002", userHash: "other-hash")
    messenger.sessionDidChange(.signedIn(Self.account(id: 2002)), identity: other)
    XCTAssertEqual(
      client.calls.suffix(2), [.logIn("2002", "other-hash"), .registerForRemoteNotifications],
      "started twice")
  }

  func testAFailedLoginStillLogsOutAndAnEarlierLaunchesUserIsLoggedOut() throws {
    let defaults = try makeDefaults()
    let failing = RecordingSupportClient(logInSucceeds: false)
    let messenger = PutioSupportMessenger(
      configuration: configuration, client: failing, defaults: defaults)
    messenger.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    XCTAssertEqual(
      failing.calls,
      [.start, .logIn("1001", "synthetic-hash"), .logOut, .registerForRemoteNotifications])

    // The app closes mid-login; the session has expired by the next launch.
    let interrupted = RecordingSupportClient(defersCompletions: true)
    PutioSupportMessenger(configuration: configuration, client: interrupted, defaults: defaults)
      .sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    let relaunched = RecordingSupportClient()
    PutioSupportMessenger(configuration: configuration, client: relaunched, defaults: defaults)
      .sessionDidChange(.signedOut(.sessionExpired), identity: nil)
    XCTAssertEqual(relaunched.calls, [.start, .logOut])

    let clean = RecordingSupportClient()
    PutioSupportMessenger(configuration: configuration, client: clean, defaults: defaults)
      .sessionDidChange(.signedOut(.sessionExpired), identity: nil)
    XCTAssertEqual(clean.calls, [], "logged out a user nobody logged in")
  }

  func testALateFailureOfAnEarlierLoginKeepsTheNewerOne() throws {
    let client = RecordingSupportClient(defersCompletions: true)
    let messenger = try makeMessenger(client)
    messenger.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    messenger.sessionDidChange(.signedOut(.userSignedOut), identity: nil)
    messenger.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)

    client.complete(0, succeeded: false)
    client.complete(1, succeeded: true)

    XCTAssertEqual(messenger.login, .loggedIn(userID: "1001"))
    XCTAssertEqual(client.calls.filter { $0 == .logOut }.count, 1, "the stale failure logged out")
  }

  func testALateLoginOfThePreviousUserIsLoggedOutBeforeTheNextOne() throws {
    let client = RecordingSupportClient(defersCompletions: true)
    let messenger = try makeMessenger(client)
    let other = PutioSupportIdentity(userID: "2002", userHash: "other-hash")
    messenger.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    messenger.sessionDidChange(.signedOut(.userSignedOut), identity: nil)
    messenger.sessionDidChange(.signedIn(Self.account(id: 2002)), identity: other)
    XCTAssertEqual(
      client.calls.filter { $0 != .registerForRemoteNotifications },
      [.start, .logIn("1001", "synthetic-hash")], "logins overlapped")

    client.complete(0, succeeded: true)
    XCTAssertEqual(
      client.calls.filter { $0 != .registerForRemoteNotifications },
      [.start, .logIn("1001", "synthetic-hash"), .logOut, .logIn("2002", "other-hash")])
    client.complete(1, succeeded: true)
    XCTAssertEqual(messenger.login, .loggedIn(userID: "2002"))
  }

  func testARelaunchReusesTheSameUserAndReplacesAnotherOne() throws {
    let defaults = try makeDefaults()
    let first = RecordingSupportClient()
    PutioSupportMessenger(configuration: configuration, client: first, defaults: defaults)
      .sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)

    let sameUser = RecordingSupportClient()
    PutioSupportMessenger(configuration: configuration, client: sameUser, defaults: defaults)
      .sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    XCTAssertEqual(
      sameUser.calls, [.start, .logIn("1001", "synthetic-hash"), .registerForRemoteNotifications])

    let other = PutioSupportIdentity(userID: "2002", userHash: "other-hash")
    let otherUser = RecordingSupportClient()
    PutioSupportMessenger(configuration: configuration, client: otherUser, defaults: defaults)
      .sessionDidChange(.signedIn(Self.account(id: 2002)), identity: other)
    XCTAssertEqual(
      otherUser.calls,
      [.start, .logOut, .logIn("2002", "other-hash"), .registerForRemoteNotifications])
  }

  func testTheDeviceTokenReachesIntercomOnlyOnceItStarted() throws {
    let token = Data([0xAB, 0xCD])
    let client = RecordingSupportClient()
    let messenger = try makeMessenger(client)
    messenger.didRegisterForRemoteNotifications(deviceToken: token)
    XCTAssertEqual(client.calls, [], "handed the token to Intercom before it started")

    messenger.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    XCTAssertEqual(client.calls.prefix(2), [.start, .setDeviceToken(token)])

    let renewed = Data([0x01])
    messenger.didRegisterForRemoteNotifications(deviceToken: renewed)
    XCTAssertEqual(client.calls.last, .setDeviceToken(renewed))

    let switchedOff = RecordingSupportClient()
    let off = PutioSupportMessenger(
      configuration: nil, client: switchedOff, defaults: try makeDefaults())
    off.didRegisterForRemoteNotifications(deviceToken: token)
    off.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    XCTAssertEqual(switchedOff.calls, [], "registered for push with Intercom switched off")
  }

  func testAReplyNotificationOpensTheMessengerOnceTheAccountIsLoggedIn() throws {
    let reply: [AnyHashable: Any] = ["intercom_push_type": "notification", "conversation_id": "7"]
    let client = RecordingSupportClient(defersCompletions: true)
    let messenger = try makeMessenger(client)

    messenger.open(notification: reply)
    messenger.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    XCTAssertFalse(client.calls.contains(.openNotification("7")), "opened before the login")
    client.complete(0, succeeded: true)
    XCTAssertEqual(client.calls.last, .openNotification("7"))

    messenger.open(notification: ["aps": ["alert": "Download finished"]])
    XCTAssertEqual(client.calls.filter { $0 == .openNotification("7") }.count, 1)
    messenger.open(notification: reply)
    XCTAssertEqual(client.calls.filter { $0 == .openNotification("7") }.count, 2)
  }

  func testAReplyNotificationIsDroppedWhenTheSessionEndsFirst() throws {
    let reply: [AnyHashable: Any] = ["intercom_push_type": "notification", "conversation_id": "7"]
    let client = RecordingSupportClient()
    let messenger = try makeMessenger(client)

    messenger.open(notification: reply)
    messenger.sessionDidChange(.signedOut(.sessionExpired), identity: nil)
    messenger.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    XCTAssertFalse(client.calls.contains(.openNotification("7")), "opened for a later session")

    messenger.sessionDidChange(.signedOut(.userSignedOut), identity: nil)
    messenger.open(notification: reply)
    let other = PutioSupportIdentity(userID: "2002", userHash: "other-hash")
    messenger.sessionDidChange(.signedIn(Self.account(id: 2002)), identity: other)
    XCTAssertFalse(
      client.calls.contains(.openNotification("7")), "opened a signed-out tap for the next account")
  }

  func testContactUsWaitsForTheLoginAndRetriesAFailedOneOnce() throws {
    var opened: [URL] = []
    let client = RecordingSupportClient(defersCompletions: true)
    let messenger = try makeMessenger(client)
    messenger.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)

    messenger.contactSupport { opened.append($0) }
    XCTAssertEqual(opened, [email], "opened the messenger before the login finished")
    client.complete(0, succeeded: false)

    messenger.contactSupport { opened.append($0) }
    XCTAssertEqual(client.calls.filter { $0 == .logIn("1001", "synthetic-hash") }.count, 2)
    client.complete(1, succeeded: true)
    XCTAssertEqual(client.calls.last, .present)

    let failing = RecordingSupportClient(logInSucceeds: false)
    let rejected = try makeMessenger(failing)
    rejected.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    rejected.contactSupport { opened.append($0) }
    rejected.contactSupport { opened.append($0) }
    XCTAssertEqual(failing.calls.filter { $0 == .logIn("1001", "synthetic-hash") }.count, 2)
    XCTAssertFalse(failing.calls.contains(.present))
    XCTAssertEqual(opened, [email, email, email])
  }

  func testFallsBackToEmailWithoutKeysOrHash() throws {
    var opened: [URL] = []
    let switchedOff = RecordingSupportClient()
    let off = PutioSupportMessenger(
      configuration: nil, client: switchedOff, defaults: try makeDefaults())
    off.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: identity)
    off.contactSupport { opened.append($0) }
    XCTAssertEqual(switchedOff.calls, [])

    let unverified = RecordingSupportClient()
    let noHash = try makeMessenger(unverified)
    noHash.sessionDidChange(.signedIn(Self.account(id: 1001)), identity: nil)
    noHash.contactSupport { opened.append($0) }
    XCTAssertEqual(unverified.calls, [])

    XCTAssertEqual(opened, [email, email])
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

  private func makeMessenger(_ client: RecordingSupportClient) throws -> PutioSupportMessenger {
    PutioSupportMessenger(
      configuration: configuration, client: client, defaults: try makeDefaults())
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "SupportMessengerTests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
    return try XCTUnwrap(UserDefaults(suiteName: suiteName))
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
    case registerForRemoteNotifications
    case setDeviceToken(Data)
    case openNotification(String?)
  }

  private(set) var calls: [Call] = []
  private var pending: [@MainActor (Bool) -> Void] = []
  private let logInSucceeds: Bool
  private let defersCompletions: Bool

  init(logInSucceeds: Bool = true, defersCompletions: Bool = false) {
    self.logInSucceeds = logInSucceeds
    self.defersCompletions = defersCompletions
  }

  /// Finishes the `index`th login, in whatever order the test needs.
  func complete(_ index: Int, succeeded: Bool) {
    pending[index](succeeded)
  }

  func start(_ configuration: IntercomConfiguration) { calls.append(.start) }

  func logIn(_ identity: PutioSupportIdentity, completion: @escaping @MainActor (Bool) -> Void) {
    calls.append(.logIn(identity.userID, identity.userHash))
    if defersCompletions {
      pending.append(completion)
    } else {
      completion(logInSucceeds)
    }
  }

  func logOut() { calls.append(.logOut) }

  func present() { calls.append(.present) }

  func registerForRemoteNotifications() { calls.append(.registerForRemoteNotifications) }

  func setDeviceToken(_ token: Data) { calls.append(.setDeviceToken(token)) }

  func isSupportNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    userInfo["intercom_push_type"] != nil
  }

  func openNotification(_ userInfo: [AnyHashable: Any]) {
    calls.append(.openNotification(userInfo["conversation_id"] as? String))
  }
}
