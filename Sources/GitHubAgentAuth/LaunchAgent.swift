import Darwin
import Foundation

enum LaunchAgent {
  static func migrateIfNeeded(binary: URL, config: URL = Paths.config, socket: URL = Paths.socket)
    throws
  {
    guard FileManager.default.fileExists(atPath: Paths.legacyLaunchAgent.path) else { return }
    try install(binary: binary, config: config, socket: socket)
  }

  static func install(binary: URL, config: URL = Paths.config, socket: URL = Paths.socket) throws {
    try removeLegacyAgent()
    let plist: [String: Any] = [
      "Label": service,
      "ProgramArguments": [
        binary.path, "--config", config.path, "--socket", socket.path, "daemon",
      ],
      "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Background",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try FileManager.default.createDirectory(
      at: Paths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: Paths.launchAgent, options: .atomic)
    try setMode(Paths.launchAgent.path, 0o600)
    _ = try? runProcess("/bin/launchctl", ["bootout", domain, Paths.launchAgent.path])
    let result = try runProcess("/bin/launchctl", ["bootstrap", domain, Paths.launchAgent.path])
    guard result.0 == 0 else { throw AppError.config("launchctl bootstrap failed") }
  }

  static func restart() throws {
    let result = try runProcess("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(service)"])
    guard result.0 == 0 else {
      throw AppError.config("configuration saved, but broker restart failed")
    }
  }

  static func uninstall() throws {
    for path in [Paths.launchAgent, Paths.legacyLaunchAgent]
    where FileManager.default.fileExists(atPath: path.path) {
      _ = try? runProcess("/bin/launchctl", ["bootout", domain, path.path])
      try FileManager.default.removeItem(at: path)
    }
  }

  private static func removeLegacyAgent() throws {
    guard FileManager.default.fileExists(atPath: Paths.legacyLaunchAgent.path) else { return }
    _ = try? runProcess("/bin/launchctl", ["bootout", domain, Paths.legacyLaunchAgent.path])
    try FileManager.default.removeItem(at: Paths.legacyLaunchAgent)
  }

  private static var domain: String { "gui/\(getuid())" }
}
