import Foundation

enum SecretStore {
  static func install(_ pem: Data, at url: URL = Paths.privateKey) throws {
    guard geteuid() == 0 else { throw AppError.denied("private-key installation requires root") }
    guard !pem.isEmpty else { throw AppError.config("private key is empty") }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    let temporary = url.appendingPathExtension("tmp")
    try pem.write(to: temporary, options: .atomic)
    try setMode(temporary.path, 0o600)
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: url)
    }
  }

  static func load(from url: URL = Paths.privateKey) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0 else {
      throw AppError.config("private key must be owned by root")
    }
    guard ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o077 == 0 else {
      throw AppError.config("private key must have mode 0600")
    }
    return try Data(contentsOf: url)
  }

  static func delete(at url: URL = Paths.privateKey) throws {
    guard geteuid() == 0 else { throw AppError.denied("private-key deletion requires root") }
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}
