import Foundation
import Security
import Synchronization

public enum PutioTokenStoreError: Error, Equatable {
  case keychainFailure(OSStatus)
}

public protocol PutioTokenStore: Sendable {
  func read() throws -> String?
  func write(_ token: String) throws
  func clear() throws
}

// Keychain-backed token storage keyed to the app identity. The token is
// available after first unlock so a background relaunch can restore the
// session, and it never syncs off the device.
public struct PutioKeychainTokenStore: PutioTokenStore {
  private let service: String
  private let account = "putio-oauth-token"

  public init(service: String? = nil) {
    self.service = service ?? Bundle.main.bundleIdentifier ?? "io.put.dev"
  }

  public func read() throws -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data, let token = String(data: data, encoding: .utf8),
        !token.isEmpty
      else {
        return nil
      }
      return token
    case errSecItemNotFound:
      return nil
    default:
      throw PutioTokenStoreError.keychainFailure(status)
    }
  }

  public func write(_ token: String) throws {
    let data = Data(token.utf8)
    var update = [String: Any]()
    update[kSecValueData as String] = data

    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw PutioTokenStoreError.keychainFailure(updateStatus)
    }

    var add = baseQuery
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw PutioTokenStoreError.keychainFailure(addStatus)
    }
  }

  public func clear() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PutioTokenStoreError.keychainFailure(status)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

public final class PutioInMemoryTokenStore: PutioTokenStore {
  private let token: Mutex<String?>

  public init(token: String? = nil) {
    self.token = Mutex(token)
  }

  public func read() throws -> String? {
    token.withLock { $0 }
  }

  public func write(_ token: String) throws {
    self.token.withLock { $0 = token }
  }

  public func clear() throws {
    token.withLock { $0 = nil }
  }
}
