import Foundation

struct Configuration: Codable, Sendable {
  struct GitHub: Codable, Sendable {
    var host: String
    var appID: UInt64
  }
  struct Installation: Codable, Sendable {
    var owner: String
    var installationID: UInt64
    var repositories: [String]
  }
  struct GH: Codable, Sendable { var binary: String }

  var version = 1
  var github: GitHub
  var installations: [Installation] = []
  var gh: GH?
  var permissionProfile: String?

  func validate() throws {
    guard version == 1 else { throw AppError.config("only version 1 is supported") }
    guard github.host == gitHubHost, github.appID > 0 else {
      throw AppError.config("host must be github.com and app ID must be positive")
    }
    for installation in installations {
      try Repository.validate(installation.owner)
      guard installation.installationID > 0, !installation.repositories.isEmpty else {
        throw AppError.config("installation \(installation.owner) must have an ID and repositories")
      }
      for repository in installation.repositories { try Repository.validate(repository) }
    }
    if let binary = gh?.binary, !binary.hasPrefix("/") {
      throw AppError.config("gh binary path must be absolute")
    }
  }

  static func load(from url: URL = Paths.config) throws -> Self {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let permissions = attributes[.posixPermissions] as? NSNumber,
      permissions.uint16Value & 0o077 != 0
    {
      throw AppError.config("\(url.path) must not be accessible by group or others")
    }
    let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    try value.validate()
    return value
  }

  func save(to url: URL = Paths.config) throws {
    try validate()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = url.appendingPathExtension("tmp")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: temporary, options: .atomic)
    try setMode(temporary.path, 0o600)
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(
        url, withItemAt: temporary, backupItemName: nil, options: [])
    } else {
      try FileManager.default.moveItem(at: temporary, to: url)
    }
  }
}

struct Repository: Hashable, Sendable, CustomStringConvertible {
  let owner: String, name: String
  var description: String { "\(owner)/\(name)" }

  init(_ value: String) throws {
    let normalized = value.hasSuffix(".git") ? String(value.dropLast(4)) : value
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2 else { throw AppError.denied("repository must be owner/name") }
    try Self.validate(String(components[0]))
    try Self.validate(String(components[1]))
    owner = components[0].lowercased()
    name = components[1].lowercased()
  }

  static func validate(_ value: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard !value.isEmpty, value.count <= 100, value != ".", value != "..",
      value.unicodeScalars.allSatisfy(allowed.contains)
    else {
      throw AppError.denied("invalid repository component: \(value)")
    }
  }
}

extension Configuration {
  func installationID(for repository: Repository) throws -> UInt64 {
    guard
      let match = installations.first(where: {
        $0.owner.caseInsensitiveCompare(repository.owner) == .orderedSame
          && $0.repositories.contains { $0.caseInsensitiveCompare(repository.name) == .orderedSame }
      })
    else { throw AppError.denied("repository \(repository) is not allowed") }
    return match.installationID
  }
}
