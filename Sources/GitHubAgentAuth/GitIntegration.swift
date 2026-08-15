import Darwin
import Foundation

enum GitIntegration {
  static func currentRepository() throws -> Repository {
    let (status, output, _) = try runProcess("/usr/bin/git", ["remote", "get-url", "origin"])
    guard status == 0, let remote = String(data: output, encoding: .utf8) else {
      throw AppError.denied("run this command inside a Git repository with an origin remote")
    }
    return try repository(remote: remote.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func credential(operation: String) throws {
    guard operation == "get" else {
      if operation == "store" || operation == "erase" { return }
      throw AppError.config("unsupported Git credential operation: \(operation)")
    }
    var fields: [String: String] = [:]
    while let line = readLine(), !line.isEmpty {
      if let separator = line.firstIndex(of: "=") {
        fields[String(line[..<separator])] = String(line[line.index(after: separator)...])
      }
    }
    guard fields["protocol"] == "https", fields["host"] == gitHubHost else {
      throw AppError.denied("Git endpoint must be HTTPS on exactly github.com")
    }
    guard let path = fields["path"] else {
      throw AppError.denied("Git did not provide a repository path; enable useHttpPath")
    }
    let repository = try Repository(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    let response = try Broker.request(
      .init(version: 1, operation: .gitCredential, repository: repository.description))
    guard let username = response.username, let token = response.token else {
      throw AppError.broker("credential response incomplete")
    }
    print("username=\(username)\npassword=\(token)\n")
  }

  static func repository(remote: String) throws -> Repository {
    guard let components = URLComponents(string: remote), components.scheme == "https",
      components.host == gitHubHost, components.user == nil, components.password == nil,
      components.port == nil, components.query == nil, components.fragment == nil
    else {
      throw AppError.denied(
        "Git remote must be HTTPS on exactly github.com without credentials or port")
    }
    return try Repository(components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
  }

  static func runGH(configuration: Configuration, arguments: [String]) throws -> Never {
    guard let realPath = configuration.gh?.binary else {
      throw AppError.config("real gh binary is not configured")
    }
    let real = URL(fileURLWithPath: realPath).resolvingSymlinksInPath()
    let current = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    guard real != current else { throw AppError.config("gh wrapper recursion detected") }
    let repository = try currentRepository()
    let response = try Broker.request(
      .init(version: 1, operation: .ghToken, repository: repository.description))
    guard let token = response.token else { throw AppError.broker("token response incomplete") }
    var environment = ProcessInfo.processInfo.environment
    for variable in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] {
      environment.removeValue(forKey: variable)
    }
    environment["GH_TOKEN"] = token
    environment["GH_HOST"] = gitHubHost
    let argv = ([realPath] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    execve(realPath, argv, envp)
    throw AppError.system("execve", errno)
  }
}
