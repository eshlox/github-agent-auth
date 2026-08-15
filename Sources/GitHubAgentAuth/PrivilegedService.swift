import Darwin
import Foundation

struct InstallPayload: Codable {
  let configuration: Configuration
  let privateKey: Data
  let ghSource: String
}

enum PrivilegedService {
  static func install(payload: InstallPayload, sourceBinary: URL) throws {
    guard geteuid() == 0 else { throw AppError.denied("service installation requires root") }
    try validateSudoCaller(payload.configuration.allowedUID)
    try validateTool(payload.configuration.tooling.gitRemoteHTTPBinary)
    var configuration = payload.configuration
    let worker = try ensureServiceAccount()
    configuration.workerUID = worker.uid
    configuration.workerGID = worker.gid
    try installBinary(from: sourceBinary)
    try installGH(from: URL(fileURLWithPath: payload.ghSource))
    try configuration.save()
    try SecretStore.install(payload.privateKey)
    for directory in [Paths.isolatedGHDirectory, Paths.privateTemporaryDirectory] {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      guard chown(directory.path, worker.uid, worker.gid) == 0 else {
        throw AppError.system("protect broker worker directory", errno)
      }
      try setMode(directory.path, 0o700)
    }
    try installLaunchDaemon()
  }

  static func update(_ operation: String, arguments: [String]) throws {
    guard geteuid() == 0 else { throw AppError.denied("configuration update requires root") }
    var config = try Configuration.load()
    try validateSudoCaller(config.allowedUID)
    switch operation {
    case "permissions":
      guard arguments.count == 1, let profile = PermissionProfile(rawValue: arguments[0]) else {
        throw AppError.config("permissions requires core or ci-read")
      }
      config.permissionProfile = profile.rawValue
    case "repo-add":
      guard arguments.count == 1 else { throw AppError.config("repo-add requires OWNER/REPO") }
      let repository = try Repository(arguments[0])
      guard
        let index = config.installations.firstIndex(where: {
          $0.owner.caseInsensitiveCompare(repository.owner) == .orderedSame
        })
      else { throw AppError.denied("no App installation is configured for \(repository.owner)") }
      if !config.installations[index].repositories.contains(where: {
        $0.caseInsensitiveCompare(repository.name) == .orderedSame
      }) {
        var candidate = config
        candidate.installations[index].repositories.append(repository.name)
        let verifiedCandidate = candidate
        _ = try blockingAsync {
          try await GitHubClient.mint(configuration: verifiedCandidate, repository: repository)
        }
        config = candidate
      }
    case "repo-remove":
      guard arguments.count == 1 else { throw AppError.config("repo-remove requires OWNER/REPO") }
      let repository = try Repository(arguments[0])
      guard
        let index = config.installations.firstIndex(where: {
          $0.owner.caseInsensitiveCompare(repository.owner) == .orderedSame
        })
      else { throw AppError.denied("repository is not configured") }
      config.installations[index].repositories.removeAll {
        $0.caseInsensitiveCompare(repository.name) == .orderedSame
      }
      if config.installations[index].repositories.isEmpty { config.installations.remove(at: index) }
    default: throw AppError.config("unknown privileged update")
    }
    try config.save()
    try kickstart()
  }

  static func refresh(sourceBinary: URL, ghSource: URL) throws {
    guard geteuid() == 0 else { throw AppError.denied("service refresh requires root") }
    let config = try Configuration.load()
    try validateSudoCaller(config.allowedUID)
    try installBinary(from: sourceBinary)
    try installGH(from: ghSource)
    try kickstart()
  }

  static func updateGH(from source: URL) throws {
    guard geteuid() == 0 else { throw AppError.denied("GitHub CLI update requires root") }
    let config = try Configuration.load()
    try validateSudoCaller(config.allowedUID)
    try installGH(from: source)
  }

  static func uninstall() throws {
    guard geteuid() == 0 else { throw AppError.denied("service removal requires root") }
    let installedConfiguration = try? Configuration.load()
    if let config = installedConfiguration { try validateSudoCaller(config.allowedUID) }
    _ = try? runProcess("/bin/launchctl", ["bootout", "system/\(service)"])
    for path in privilegedArtifactPaths { try removeIfPresent(path) }
    try SecretStore.delete()
    try removeIfPresent(Paths.config)
    try removeIfPresent(Paths.privilegedBinary)
    try removeIfPresent(Paths.privilegedGH)
    for directory in privilegedDirectoryPaths { try removeIfPresent(directory) }
    if let config = installedConfiguration,
      let worker = try? brokerWorkerIdentity(), worker.uid == config.workerUID,
      worker.gid == config.workerGID
    {
      try deleteDirectoryServiceRecord("/Users/\(serviceAccount)")
      try deleteDirectoryServiceRecord("/Groups/\(serviceAccount)")
    }
  }

  static let privilegedArtifactPaths = [
    Paths.launchDaemon, Paths.socket, Paths.auditLog, Paths.daemonLog,
  ]

  static let privilegedDirectoryPaths = [
    Paths.isolatedGHDirectory, Paths.privateTemporaryDirectory, Paths.systemDirectory,
    Paths.socketDirectory,
  ]

  static func invoke(_ arguments: [String], standardInput: Data? = nil) throws {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = [executable.path] + arguments
    if let standardInput {
      let pipe = Pipe()
      process.standardInput = pipe
      try process.run()
      try pipe.fileHandleForWriting.write(contentsOf: standardInput)
      try pipe.fileHandleForWriting.close()
    } else {
      try process.run()
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw AppError.config("privileged operation failed")
    }
  }

  private static func installBinary(from source: URL) throws {
    try FileManager.default.createDirectory(
      at: Paths.privilegedBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try installExecutable(from: source, to: Paths.privilegedBinary)
  }

  private static func installGH(from source: URL) throws {
    guard FileManager.default.isExecutableFile(atPath: source.path) else {
      throw AppError.denied("GitHub CLI source is not executable")
    }
    try installExecutable(from: source, to: Paths.privilegedGH)
  }

  private static func removeIfPresent(_ path: URL) throws {
    if FileManager.default.fileExists(atPath: path.path) {
      try FileManager.default.removeItem(at: path)
    }
  }

  private static func deleteDirectoryServiceRecord(_ record: String) throws {
    let result = try runProcess("/usr/bin/dscl", [".", "-delete", record])
    guard result.0 == 0 else { throw AppError.config("could not remove \(record)") }
  }

  private static func installExecutable(from source: URL, to destination: URL) throws {
    let temporary = destination.appendingPathExtension("new")
    if FileManager.default.fileExists(atPath: temporary.path) {
      try FileManager.default.removeItem(at: temporary)
    }
    try FileManager.default.copyItem(at: source, to: temporary)
    do {
      try setMode(temporary.path, 0o755)
      let signature = try runProcess("/usr/bin/codesign", ["--verify", "--strict", temporary.path])
      guard signature.0 == 0 else {
        throw AppError.denied("executable signature is invalid")
      }
      guard Darwin.rename(temporary.path, destination.path) == 0 else {
        throw AppError.system("install privileged executable", errno)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  private static func installLaunchDaemon() throws {
    let plist: [String: Any] = [
      "Label": service, "ProgramArguments": [Paths.privilegedBinary.path, "daemon"],
      "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Background",
      "StandardErrorPath": Paths.daemonLog.path, "Umask": 0o077,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: Paths.launchDaemon, options: .atomic)
    try setMode(Paths.launchDaemon.path, 0o644)
    _ = try? runProcess("/bin/launchctl", ["bootout", "system/\(service)"])
    let result = try runProcess("/bin/launchctl", ["bootstrap", "system", Paths.launchDaemon.path])
    guard result.0 == 0 else { throw AppError.config("launchctl bootstrap failed") }
  }

  private static func kickstart() throws {
    let result = try runProcess("/bin/launchctl", ["kickstart", "-k", "system/\(service)"])
    guard result.0 == 0 else { throw AppError.config("launch daemon restart failed") }
  }

  private static func validateSudoCaller(_ expectedUID: UInt32) throws {
    guard let raw = ProcessInfo.processInfo.environment["SUDO_UID"], UInt32(raw) == expectedUID
    else {
      throw AppError.denied(
        "privileged command must be invoked by the configured user through sudo")
    }
  }

  private static func ensureServiceAccount() throws -> (uid: uid_t, gid: gid_t) {
    if let existing = try? brokerWorkerIdentity() {
      guard let group = getgrnam(serviceAccount), group.pointee.gr_gid == existing.gid else {
        throw AppError.denied("broker service account group is invalid")
      }
      return existing
    }
    guard getgrnam(serviceAccount) == nil else {
      throw AppError.denied("broker service account group exists without its user")
    }
    let identifier = try availableServiceIdentifier()
    let groupPath = "/Groups/\(serviceAccount)"
    let userPath = "/Users/\(serviceAccount)"
    do {
      try dscl(["-create", groupPath])
      try dscl(["-create", groupPath, "PrimaryGroupID", String(identifier)])
      try dscl(["-create", groupPath, "Password", "*"])
      try dscl(["-create", userPath])
      try dscl(["-create", userPath, "UniqueID", String(identifier)])
      try dscl(["-create", userPath, "PrimaryGroupID", String(identifier)])
      try dscl(["-create", userPath, "NFSHomeDirectory", Paths.systemDirectory.path])
      try dscl(["-create", userPath, "UserShell", "/usr/bin/false"])
      try dscl(["-create", userPath, "RealName", "AgentAuth Broker Worker"])
      try dscl(["-create", userPath, "IsHidden", "1"])
      try dscl(["-create", userPath, "Password", "*"])
      try dscl(["-create", userPath, "AuthenticationAuthority", ";DisabledUser;"])
    } catch {
      _ = try? runProcess("/usr/bin/dscl", [".", "-delete", userPath])
      _ = try? runProcess("/usr/bin/dscl", [".", "-delete", groupPath])
      throw error
    }
    return (uid_t(identifier), gid_t(identifier))
  }

  private static func availableServiceIdentifier() throws -> UInt32 {
    let users = try runProcess("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"])
    let groups = try runProcess("/usr/bin/dscl", [".", "-list", "/Groups", "PrimaryGroupID"])
    guard users.0 == 0, groups.0 == 0 else {
      throw AppError.config("could not enumerate local account identifiers")
    }
    let output = users.1 + groups.1
    let used = Set(
      (String(data: output, encoding: .utf8) ?? "").split(whereSeparator: { $0.isWhitespace })
        .compactMap { UInt32($0) })
    guard let identifier = (401...499).reversed().first(where: { !used.contains(UInt32($0)) })
    else {
      throw AppError.config("no private service-account identifier is available")
    }
    return UInt32(identifier)
  }

  private static func dscl(_ arguments: [String]) throws {
    let result = try runProcess("/usr/bin/dscl", ["."] + arguments)
    guard result.0 == 0 else { throw AppError.config("could not create broker service account") }
  }

  private static func validateTool(_ path: String) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
      ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o022 == 0
    else {
      throw AppError.denied("broker tool must be root-owned and not writable by group or others")
    }
  }
}
