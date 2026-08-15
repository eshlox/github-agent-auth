import Foundation
import Security

enum Keychain {
  private static func account(_ appID: UInt64) -> String { "github-app-private-key:\(appID)" }

  static func store(_ pem: Data, appID: UInt64) throws {
    guard !pem.isEmpty else { throw AppError.keychain("private key is empty") }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account(appID),
    ]
    SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData as String] = pem
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw failure(status) }
  }

  static func load(appID: UInt64) throws -> Data {
    let (status, data) = loadResult(appID: appID, service: service)
    if status == errSecSuccess, let data { return data }
    guard status == errSecItemNotFound else { throw failure(status) }
    let pem = try load(appID: appID, service: legacyService)
    try store(pem, appID: appID)
    try delete(appID: appID, service: legacyService)
    return pem
  }

  private static func load(appID: UInt64, service serviceName: String) throws -> Data {
    let (status, data) = loadResult(appID: appID, service: serviceName)
    guard status == errSecSuccess, let data else { throw failure(status) }
    return data
  }

  private static func loadResult(appID: UInt64, service serviceName: String) -> (OSStatus, Data?) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account(appID),
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, result as? Data)
  }

  static func delete(appID: UInt64) throws {
    try delete(appID: appID, service: service)
    try delete(appID: appID, service: legacyService)
  }

  private static func delete(appID: UInt64, service serviceName: String) throws {
    let status = SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: account(appID),
      ] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
  }

  private static func failure(_ status: OSStatus) -> AppError {
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
    return .keychain("\(message) (no filesystem fallback)")
  }
}
