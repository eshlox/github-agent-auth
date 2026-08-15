import Foundation

enum GitIntegration {
  static func currentRepository() throws -> Repository {
    let (status, output, _) = try runProcess("/usr/bin/git", ["remote", "get-url", "origin"])
    guard status == 0, let remote = String(data: output, encoding: .utf8) else {
      throw AppError.denied("run this command inside a Git repository with an origin remote")
    }
    return try repository(remote: remote.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func repository(remote: String) throws -> Repository {
    let normalized = remote.hasPrefix("agentauth::") ? String(remote.dropFirst(11)) : remote
    guard let components = URLComponents(string: normalized), components.scheme == "https",
      components.host == gitHubHost, components.user == nil, components.password == nil,
      components.port == nil, components.query == nil, components.fragment == nil
    else {
      throw AppError.denied(
        "Git remote must be HTTPS on exactly github.com without credentials or port")
    }
    return try Repository(components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
  }

  static func runGH(arguments: [String]) throws -> Never {
    let repository = try currentRepository()
    _ = try CommandPolicy.validateGH(arguments)
    try BrokerClient.runGH(repository: repository, arguments: arguments)
  }

  static func runRemoteHelper(arguments: [String]) throws -> Never {
    guard arguments.count == 2 else {
      throw AppError.config("git-remote-agentauth requires a remote name and URL")
    }
    let repository = try repository(remote: arguments[1])
    try BrokerClient.runGitRemote(repository: repository, remoteName: arguments[0])
  }
}
