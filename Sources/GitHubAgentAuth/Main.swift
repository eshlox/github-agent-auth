import Foundation

@main enum Main {
  static func main() {
    do { try run() } catch {
      FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  static func run() throws {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "gh" {
      try LaunchAgent.migrateIfNeeded(binary: executable)
      try GitIntegration.runGH(
        configuration: Configuration.load(), arguments: Array(CommandLine.arguments.dropFirst()))
    }
    var arguments = Array(CommandLine.arguments.dropFirst())
    var configURL = Paths.config
    var socketURL = Paths.socket
    consumeOption("--config", from: &arguments).map { configURL = URL(fileURLWithPath: $0) }
    consumeOption("--socket", from: &arguments).map { socketURL = URL(fileURLWithPath: $0) }
    guard let command = arguments.first else {
      printUsage()
      return
    }
    arguments.removeFirst()
    if !["uninstall", "self-test", "help", "--help", "-h", "daemon"].contains(command) {
      try LaunchAgent.migrateIfNeeded(binary: executable, config: configURL, socket: socketURL)
    }
    switch command {
    case "setup": try setup(arguments, configURL: configURL, socketURL: socketURL)
    case "add-installation":
      try mutate(configURL, arguments) { config, options in
        let owner = try required("--owner", options)
        let id = try uint("--installation-id", options)
        let repositories = try required("--repositories", options).split(separator: ",").map(
          String.init)
        config.installations.removeAll { $0.owner.caseInsensitiveCompare(owner) == .orderedSame }
        config.installations.append(
          .init(owner: owner, installationID: id, repositories: repositories))
      }
    case "add-repo", "remove-repo":
      try mutate(configURL, arguments) { config, values in
        guard values.count == 2,
          let index = config.installations.firstIndex(where: {
            $0.owner.caseInsensitiveCompare(values[0]) == .orderedSame
          })
        else {
          throw AppError.config("usage: \(command) OWNER REPOSITORY")
        }
        if command == "add-repo" {
          if !config.installations[index].repositories.contains(where: {
            $0.caseInsensitiveCompare(values[1]) == .orderedSame
          }) {
            config.installations[index].repositories.append(values[1])
          }
        } else {
          config.installations[index].repositories.removeAll {
            $0.caseInsensitiveCompare(values[1]) == .orderedSame
          }
        }
      }
    case "list": printConfiguration(try Configuration.load(from: configURL))
    case "repo": try repositoryCommand(arguments, configURL: configURL)
    case "permissions": try permissionsCommand(arguments, configURL: configURL)
    case "status": try status(configURL, socketURL)
    case "doctor": try doctor(configURL, socketURL)
    case "self-test": try SelfTest.run()
    case "uninstall":
      try uninstall(configURL, socketURL, deleteKey: arguments.contains("--delete-key"))
    case "daemon":
      _ = try Broker(configuration: Configuration.load(from: configURL), socketPath: socketURL.path)
        .run()
    case "git-credential": try GitIntegration.credential(operation: arguments.first ?? "get")
    case "gh-wrapper":
      try GitIntegration.runGH(
        configuration: Configuration.load(from: configURL), arguments: arguments)
    case "help", "--help", "-h": printUsage()
    default: throw AppError.config("unknown command: \(command)")
    }
  }

  private static func setup(_ arguments: [String], configURL: URL, socketURL: URL) throws {
    if option("--app-id", arguments) != nil {
      return try setupExisting(arguments, configURL: configURL, socketURL: socketURL)
    }
    guard !FileManager.default.fileExists(atPath: configURL.path) else {
      throw AppError.config(
        "already configured; use `repo add` or uninstall the existing setup first")
    }
    let repository =
      try option("--repository", arguments).map(Repository.init)
      ?? GitIntegration.currentRepository()
    let profile = try PermissionProfile.setupValue(option("--permissions", arguments))
    let organization = option("--organization", arguments)
    print("Repository: \(repository)\nPermissions: \(profile.summary)")
    let (app, verifiedInstallation) = try ManifestFlow.createApp(
      for: repository, profile: profile, organization: organization
    )
    let pem = Data(app.pem.utf8)
    _ = try GitHubClient.makeJWT(appID: app.id, pem: pem)
    try Keychain.store(pem, appID: app.id)
    var config = Configuration(
      github: .init(host: gitHubHost, appID: app.id),
      installations: [
        .init(
          owner: verifiedInstallation.owner, installationID: verifiedInstallation.id,
          repositories: [repository.name])
      ],
      permissionProfile: profile.rawValue
    )
    try finishSetup(&config, configURL: configURL, socketURL: socketURL)
    print(
      "Setup complete for \(repository).\nPrivate key storage: macOS Keychain\nFilesystem fallback: disabled"
    )
  }

  private static func setupExisting(_ arguments: [String], configURL: URL, socketURL: URL) throws {
    let appID = try uint("--app-id", arguments)
    let profile = try PermissionProfile.setupValue(option("--permissions", arguments))
    let pemURL = URL(fileURLWithPath: try required("--private-key", arguments))
    let pem = try Data(contentsOf: pemURL)
    _ = try GitHubClient.makeJWT(appID: appID, pem: pem)
    try Keychain.store(pem, appID: appID)
    _ = try Keychain.load(appID: appID)
    let explicitGH = option("--gh-binary", arguments).map { URL(fileURLWithPath: $0) }
    let realGH = explicitGH ?? commandPath("gh", excluding: Paths.wrapper)
    var config = Configuration(github: .init(host: gitHubHost, appID: appID))
    config.permissionProfile = profile.rawValue
    if let realGH { config.gh = .init(binary: realGH.resolvingSymlinksInPath().path) }
    try finishSetup(&config, configURL: configURL, socketURL: socketURL)
    print(
      "Setup complete.\nPrivate key storage: macOS Keychain\nFilesystem fallback: disabled\nAdd an installation with `github-agent-auth add-installation`.\nThe original PEM was not deleted."
    )
  }

  private static func finishSetup(_ config: inout Configuration, configURL: URL, socketURL: URL)
    throws
  {
    if config.gh == nil, let realGH = commandPath("gh", excluding: Paths.wrapper) {
      config.gh = .init(binary: realGH.resolvingSymlinksInPath().path)
    }
    try config.save(to: configURL)
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    try LaunchAgent.install(binary: executable, config: configURL, socket: socketURL)
    try configureGit(executable)
    if config.gh != nil {
      try installWrapper(executable)
      try offerShellPathUpdate()
    }
  }

  private static func repositoryCommand(_ arguments: [String], configURL: URL) throws {
    guard let operation = arguments.first, operation == "add" || operation == "remove" else {
      throw AppError.config("usage: repo add|remove [--repository OWNER/REPO]")
    }
    let repository =
      try option("--repository", arguments).map(Repository.init)
      ?? GitIntegration.currentRepository()
    var config = try Configuration.load(from: configURL)
    guard
      let index = config.installations.firstIndex(where: {
        $0.owner.caseInsensitiveCompare(repository.owner) == .orderedSame
      })
    else { throw AppError.denied("no App installation is configured for \(repository.owner)") }
    if operation == "add" {
      if !config.installations[index].repositories.contains(where: {
        $0.caseInsensitiveCompare(repository.name) == .orderedSame
      }) {
        var candidate = config
        candidate.installations[index].repositories.append(repository.name)
        let verifiedCandidate = candidate
        do {
          _ = try verifyRepositoryAccess(configuration: verifiedCandidate, repository: repository)
        } catch AppError.github(let message)
          where message.contains("HTTP 404") || message.contains("HTTP 422")
        {
          print(
            "Select \(repository) in the GitHub App installation, then return here and press Enter."
          )
          try openURL(
            URL(
              string:
                "https://github.com/settings/installations/\(config.installations[index].installationID)"
            )!)
          _ = readLine()
          _ = try verifyRepositoryAccess(configuration: verifiedCandidate, repository: repository)
        }
        config = candidate
      }
    } else {
      config.installations[index].repositories.removeAll {
        $0.caseInsensitiveCompare(repository.name) == .orderedSame
      }
      if config.installations[index].repositories.isEmpty { config.installations.remove(at: index) }
    }
    try config.save(to: configURL)
    try LaunchAgent.restart()
    print("\(operation == "add" ? "Allowed" : "Removed") \(repository)")
  }

  private static func verifyRepositoryAccess(
    configuration: Configuration,
    repository: Repository
  ) throws -> InstallationToken {
    try blockingAsync {
      try await GitHubClient.mint(configuration: configuration, repository: repository)
    }
  }

  private static func permissionsCommand(_ arguments: [String], configURL: URL) throws {
    var config = try Configuration.load(from: configURL)
    if arguments.first == "set" {
      guard arguments.count == 2, let profile = PermissionProfile(rawValue: arguments[1]) else {
        throw AppError.config("usage: permissions set core|ci-read")
      }
      config.permissionProfile = profile.rawValue
      try config.save(to: configURL)
      try LaunchAgent.restart()
      print("Local token permission cap set to \(profile.rawValue).")
    } else if !arguments.isEmpty {
      throw AppError.config("usage: permissions [set core|ci-read]")
    }
    let profile = config.permissionProfile.flatMap(PermissionProfile.init(rawValue:))
    print("Local profile: \(profile?.rawValue ?? "unknown (existing App)")")
    if let profile { print(profile.summary) }
    print(
      "GitHub App permissions are the outer limit; this local profile is requested for every new token."
    )
  }

  private static func mutate(
    _ url: URL, _ arguments: [String], body: (inout Configuration, [String]) throws -> Void
  ) throws {
    var config = try Configuration.load(from: url)
    try body(&config, arguments)
    try config.save(to: url)
    try LaunchAgent.restart()
  }

  private static func configureGit(_ executable: URL) throws {
    let helper = "!\(shellQuote(executable.path)) git-credential"
    let current = try runProcess(
      "/usr/bin/git", ["config", "--global", "--get", "credential.https://github.com.helper"])
    if current.0 == 0,
      let value = String(data: current.1, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines), !value.isEmpty, value != helper
    {
      throw AppError.config(
        "a different github.com credential helper is configured; refusing to replace it")
    }
    for pair in [
      ("credential.https://github.com.helper", helper),
      ("credential.https://github.com.useHttpPath", "true"),
    ] {
      guard try runProcess("/usr/bin/git", ["config", "--global", pair.0, pair.1]).0 == 0 else {
        throw AppError.config("failed to configure Git")
      }
    }
  }

  private static func installWrapper(_ executable: URL) throws {
    try FileManager.default.createDirectory(
      at: Paths.wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: Paths.wrapper.path)
      || (try? Paths.wrapper.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    {
      guard
        (try? FileManager.default.destinationOfSymbolicLink(atPath: Paths.wrapper.path))
          == executable.path
      else { throw AppError.config("refusing to replace existing \(Paths.wrapper.path)") }
      try FileManager.default.removeItem(at: Paths.wrapper)
    }
    try FileManager.default.createSymbolicLink(at: Paths.wrapper, withDestinationURL: executable)
  }

  private static func offerShellPathUpdate() throws {
    let wrapperDirectory = Paths.wrapper.deletingLastPathComponent().path
    let pathDirectories =
      ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    if pathDirectories.firstIndex(of: wrapperDirectory) != nil,
      commandPath("gh")?.standardizedFileURL == Paths.wrapper.standardizedFileURL
    {
      return
    }
    guard isatty(STDIN_FILENO) == 1 else {
      print("Add `export PATH=\"$HOME/.local/bin:$PATH\"` to your shell profile before using gh.")
      return
    }
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let profileName = shell.hasSuffix("/bash") ? ".bash_profile" : ".zprofile"
    let profile = FileManager.default.homeDirectoryForCurrentUser.appending(path: profileName)
    print("Add ~/.local/bin to the front of PATH in ~/\(profileName)? [Y/n] ", terminator: "")
    guard (readLine() ?? "y").lowercased() != "n" else { return }
    let existing = (try? String(contentsOf: profile, encoding: .utf8)) ?? ""
    guard !existing.contains("$HOME/.local/bin:$PATH") else { return }
    let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
    let updated =
      existing + separator
      + "# Added by github-agent-auth\nexport PATH=\"$HOME/.local/bin:$PATH\"\n"
    try updated.write(to: profile, atomically: true, encoding: .utf8)
    print("Updated ~/\(profileName). Open a new terminal before using gh.")
  }

  private static func status(_ config: URL, _ socket: URL) throws {
    let value = try Configuration.load(from: config)
    let running =
      (try? UnixSocket.connect(path: socket.path)).map { descriptor in
        close(descriptor)
        return true
      } ?? false
    print(
      "Broker: \(running ? "running" : "not running")\nSocket: \(socket.path)\nSecret backend: macOS Keychain\nFilesystem fallback: disabled\nGitHub host: \(value.github.host)\nApp ID: \(value.github.appID)"
    )
    printConfiguration(value)
  }

  private static func doctor(_ config: URL, _ socket: URL) throws {
    let value = try Configuration.load(from: config)
    var failed = false
    check("config permissions and schema", true, &failed)
    check("GitHub host fixed to github.com", value.github.host == gitHubHost, &failed)
    check(
      "App key available in Keychain", (try? Keychain.load(appID: value.github.appID)) != nil,
      &failed)
    if value.permissionProfile == nil {
      print(
        "WARN no local token permission cap; run `github-agent-auth permissions set core|ci-read`")
    }
    check("socket exists", FileManager.default.fileExists(atPath: socket.path), &failed)
    let gitPath = try runProcess(
      "/usr/bin/git", ["config", "--global", "--get", "credential.https://github.com.useHttpPath"])
    check(
      "Git useHttpPath enabled",
      String(data: gitPath.1, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        == "true", &failed)
    for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"]
    where ProcessInfo.processInfo.environment[key] != nil {
      print("WARN persistent environment variable detected: \(key)")
    }
    if failed { throw AppError.config("one or more doctor checks failed") }
  }

  private static func uninstall(_ configURL: URL, _ socket: URL, deleteKey: Bool) throws {
    let appID = try? Configuration.load(from: configURL).github.appID
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let expectedHelper = "!\(shellQuote(executable.path)) git-credential"
    try LaunchAgent.uninstall()
    for url in [socket, configURL] where FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    let helper = try? runProcess(
      "/usr/bin/git", ["config", "--global", "--get", "credential.https://github.com.helper"])
    if helper.flatMap({ String(data: $0.1, encoding: .utf8) })?.trimmingCharacters(
      in: .whitespacesAndNewlines) == expectedHelper
    {
      _ = try? runProcess(
        "/usr/bin/git", ["config", "--global", "--unset", "credential.https://github.com.helper"])
    }
    if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: Paths.wrapper.path),
      target == executable.path
    {
      try FileManager.default.removeItem(at: Paths.wrapper)
    }
    if deleteKey, let appID { try Keychain.delete(appID: appID) }
    print("Uninstalled.")
  }

  private static func printConfiguration(_ value: Configuration) {
    for item in value.installations {
      print("\(item.owner) (\(item.installationID))")
      for repository in item.repositories { print("  \(repository)") }
    }
  }
  private static func check(_ text: String, _ success: Bool, _ failed: inout Bool) {
    print("\(success ? "OK" : "FAIL") \(text)")
    failed = failed || !success
  }
  private static func option(_ name: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
    return args[i + 1]
  }
  private static func required(_ name: String, _ args: [String]) throws -> String {
    guard let value = option(name, args) else { throw AppError.config("missing \(name)") }
    return value
  }
  private static func uint(_ name: String, _ args: [String]) throws -> UInt64 {
    guard let value = UInt64(try required(name, args)), value > 0 else {
      throw AppError.config("\(name) must be positive")
    }
    return value
  }
  private static func consumeOption(_ name: String, from args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...i + 1)
    return value
  }
  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
  private static func printUsage() {
    print(
      """
      Usage:
        github-agent-auth setup [--permissions core|ci-read] [--organization OWNER]
        github-agent-auth repo add|remove [--repository OWNER/REPO]
        github-agent-auth permissions [set core|ci-read]
        github-agent-auth list|status|doctor|self-test
        github-agent-auth uninstall [--delete-key]

      Run setup inside the first repository you want to authorize.
      """)
  }
}
