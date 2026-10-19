import Foundation
import PutioCore
import Security
import XCTest

final class KeychainTokenStoreTests: XCTestCase {
  private let service = "io.put.dev.tests.keychain-\(UUID().uuidString)"
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "putio-oauth-token",
    ]
  }

  override func tearDown() {
    SecItemDelete(query as CFDictionary)
  }

  func testOverwritingAnExistingItemReappliesTheDeviceOnlyAccessibility() throws {
    var seeded = query
    seeded[kSecValueData as String] = Data("old-token".utf8)
    seeded[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    XCTAssertEqual(SecItemAdd(seeded as CFDictionary, nil), errSecSuccess)

    let store = PutioKeychainTokenStore(service: service)
    try store.write("new-token")

    XCTAssertEqual(try store.read(), "new-token")
    var lookup = query
    lookup[kSecReturnAttributes as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    XCTAssertEqual(SecItemCopyMatching(lookup as CFDictionary, &result), errSecSuccess)
    let attributes = try XCTUnwrap(result as? [String: Any])
    XCTAssertEqual(
      attributes[kSecAttrAccessible as String] as? String,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
  }
}
