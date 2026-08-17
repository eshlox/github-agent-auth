import Darwin
import Foundation

@main enum Main {
  static func main() {
    do { try run() } catch {
      FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  static func run() throws {
    let invokedName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    let forwarded = Array(CommandLine.arguments.dropFirst())
    if invokedName == "gh" { try GitIntegration.runGH(arguments: forwarded) }
    if invokedName == "git-remote-agentauth" {
      try GitIntegration.runRemoteHelper(arguments: forwarded)
    }
    guard let command = forwarded.first else {
      printUsage()
      return
    }
    let arguments = Array(forwarded.dropFirst())
    switch command {
    case "setup": try setup(arguments)
    case "install-service": try refreshService()
    case "update-gh": try updateGH()
    case "repo": try repositoryCommand(arguments)
    case "permissions": try permissionsCommand(arguments)
    case "context": try contextCommand(arguments)
    case "list": printConfiguration(try Configuration.load())
    case "status": try status()
    case "doctor": try doctor()
    case "self-test": try SelfTest.run()
    case "uninstall": try uninstall()
    case "daemon": _ = try Broker(configuration: Configuration.load()).run()
    case "privileged-install":
      let payload = try JSONDecoder().decode(
        InstallPayload.self, from: FileHandle.standardInput.readDataToEndOfFile())
      try PrivilegedService.install(
        payload: payload,
        sourceBinary: try currentExecutableURL())
    case "privileged-update":
      guard let operation = arguments.first else {
        throw AppError.config("missing update operation")
      }
      try PrivilegedService.update(operation, arguments: Array(arguments.dropFirst()))
    case "privileged-refresh":
      guard arguments.count == 2, arguments[0] == "--gh-source" else {
        throw AppError.config("missing GitHub CLI source")
      }
      try PrivilegedService.refresh(
        sourceBinary: try currentExecutableURL(),
        ghSource: URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath())
    case "privileged-update-gh":
      guard arguments.count == 2, arguments[0] == "--gh-source" else {
        throw AppError.config("missing GitHub CLI source")
      }
      try PrivilegedService.updateGH(
        from: URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath())
    case "privileged-uninstall":
      try PrivilegedService.uninstall()
    case "help", "--help", "-h": printUsage()
    default: throw AppError.config("unknown command: \(command)")
    }
  }

  private static func setup(_ arguments: [String]) throws {
    guard !FileManager.default.fileExists(atPath: Paths.config.path) else {
      throw AppError.config("already configured; use `repo add` or uninstall first")
    }
    try validateOptions(
      arguments,
      allowed: [
        "--app-id", "--installation-id", "--private-key", "--repository", "--permissions",
      ])
    let repository =
      try option("--repository", arguments).map(Repository.init)
      ?? GitIntegration.currentRepository()
    let profile = try PermissionProfile.setupValue(option("--permissions", arguments))
    guard let appID = UInt64(try requiredOption("--app-id", arguments)), appID > 0 else {
      throw AppError.config("--app-id must be a positive integer")
    }
    guard
      let installationID = UInt64(try requiredOption("--installation-id", arguments)),
      installationID > 0
    else { throw AppError.config("--installation-id must be a positive integer") }
    let privateKeyPath = NSString(
      string: try requiredOption("--private-key", arguments)
    ).expandingTildeInPath
    let pem = try Data(contentsOf: URL(fileURLWithPath: privateKeyPath))
    let gh = try requiredTool("gh", excluding: Paths.ghWrapper)
    let remoteHTTP = try gitRemoteHTTP()
    print("Repository: \(repository)\nPermissions: \(profile.summary)")
    let verifiedInstallation = try blockingAsync {
      try await GitHubClient.verifyInstallation(
        appID: appID, pem: pem, installationID: installationID,
        repository: repository, profile: profile)
    }
    let config = Configuration(
      allowedUID: getuid(), allowedGID: getgid(), workerUID: 1, workerGID: 1,
      github: .init(host: gitHubHost, appID: appID),
      installations: [
        .init(
          owner: verifiedInstallation.owner, installationID: verifiedInstallation.id,
          repositories: [repository.name])
      ],
      tooling: .init(ghBinary: Paths.privilegedGH.path, gitRemoteHTTPBinary: remoteHTTP.path),
      permissionProfile: profile.rawValue)
    try PrivilegedService.invoke(
      ["privileged-install"],
      standardInput: try JSONEncoder().encode(
        InstallPayload(configuration: config, privateKey: pem, ghSource: gh.path)))
    try configureGit()
    try installWrappers()
    try offerShellPathUpdate()
    print(
      "Setup complete for \(repository).\nBroker: root-owned LaunchDaemon\nGitHub tokens: broker-only, short-lived, one repository"
    )
    print(
      "Delete the original private key after `github-agent-auth doctor` succeeds: \(privateKeyPath)"
    )
  }

  private static func repositoryCommand(_ arguments: [String]) throws {
    guard let operation = arguments.first, operation == "add" || operation == "remove" else {
      throw AppError.config("usage: repo add|remove [--repository OWNER/REPO]")
    }
    let repository =
      try option("--repository", arguments).map(Repository.init)
      ?? GitIntegration.currentRepository()
    let config = try Configuration.load()
    if operation == "add" {
      guard
        let installation = config.installations.first(where: {
          $0.owner.caseInsensitiveCompare(repository.owner) == .orderedSame
        })
      else { throw AppError.denied("no App installation is configured for \(repository.owner)") }
      print(
        "Select \(repository) in the GitHub App installation, then return here and press Enter.")
      try openURL(
        URL(string: "https://github.com/settings/installations/\(installation.installationID)")!)
      _ = readLine()
    }
    try PrivilegedService.invoke([
      "privileged-update", "repo-\(operation)", repository.description,
    ])
    print(operation == "add" ? "Allowed \(repository)" : "Removed \(repository)")
  }

  private static func refreshService() throws {
    let gh = try requiredTool("gh", excluding: Paths.ghWrapper)
    try PrivilegedService.invoke(["privileged-refresh", "--gh-source", gh.path])
    try installWrappers()
    print("Privileged service and protected GitHub CLI refreshed.")
  }

  private static func updateGH() throws {
    let gh = try requiredTool("gh", excluding: Paths.ghWrapper)
    print("Updating protected GitHub CLI from \(gh.path)")
    try PrivilegedService.invoke(["privileged-update-gh", "--gh-source", gh.path])
    print("Protected GitHub CLI updated.")
  }

  private static func permissionsCommand(_ arguments: [String]) throws {
    if arguments.first == "set" {
      guard arguments.count == 2, PermissionProfile(rawValue: arguments[1]) != nil else {
        throw AppError.config("usage: permissions set core|developer")
      }
      try PrivilegedService.invoke(["privileged-update", "permissions", arguments[1]])
      print("Local token permission cap set to \(arguments[1]).")
    } else if !arguments.isEmpty {
      throw AppError.config("usage: permissions [set core|developer]")
    }
    let config = try Configuration.load()
    let profile = config.permissionProfile.flatMap(PermissionProfile.init(rawValue:))
    print("Local profile: \(profile?.rawValue ?? "unknown")")
    if let profile { print(profile.summary) }
  }

  private static func contextCommand(_ arguments: [String]) throws {
    guard let name = arguments.first, let kind = ContextKind(rawValue: name) else {
      throw AppError.config(
        "usage: context code-quality|code-scanning|dependabot|deployments|discussions|merge-queue")
    }
    let repository =
      try option("--repository", arguments).map(Repository.init)
      ?? GitIntegration.currentRepository()
    let expectedCount = option("--repository", arguments) == nil ? 1 : 3
    guard arguments.count == expectedCount else {
      throw AppError.config("context accepts only an optional --repository OWNER/REPO")
    }
    try BrokerClient.runContext(repository: repository, kind: kind)
  }

  private static func configureGit() throws {
    let key = "url.agentauth::https://github.com/.insteadOf"
    let current = try runProcess("/usr/bin/git", ["config", "--global", "--get-all", key])
    if current.0 == 0 {
      let values =
        String(data: current.1, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
      guard values == ["https://github.com/"] else {
        throw AppError.config("a conflicting AgentAuth Git URL rewrite already exists")
      }
      return
    }
    guard
      try runProcess(
        "/usr/bin/git", ["config", "--global", key, "https://github.com/"]
      ).0 == 0
    else { throw AppError.config("failed to configure Git remote transport") }
  }

  private static func installWrappers() throws {
    let executable = try currentExecutableURL()
    for wrapper in [Paths.ghWrapper, Paths.gitRemoteWrapper] {
      try FileManager.default.createDirectory(
        at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: wrapper.path)
        || (try? wrapper.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
      {
        guard
          (try? FileManager.default.destinationOfSymbolicLink(atPath: wrapper.path))
            == executable.path
        else { throw AppError.config("refusing to replace existing \(wrapper.path)") }
        try FileManager.default.removeItem(at: wrapper)
      }
      try FileManager.default.createSymbolicLink(at: wrapper, withDestinationURL: executable)
    }
  }

  private static func offerShellPathUpdate() throws {
    let directory = Paths.ghWrapper.deletingLastPathComponent().path
    let path =
      ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    if path.contains(directory) { return }
    guard isatty(STDIN_FILENO) == 1 else {
      print("Add `export PATH=\"$HOME/.local/bin:$PATH\"` to your shell profile.")
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
    try
      (existing + separator
      + "# Added by github-agent-auth\nexport PATH=\"$HOME/.local/bin:$PATH\"\n")
      .write(to: profile, atomically: true, encoding: .utf8)
  }

  private static func status() throws {
    let config = try Configuration.load()
    let running = (try? BrokerClient.ping()) != nil
    print("Broker: \(running ? "running" : "not running")")
    print("Service: root-owned LaunchDaemon\nSocket: \(Paths.socket.path)")
    print("GitHub host: \(config.github.host)\nApp ID: \(config.github.appID)")
    printConfiguration(config)
  }

  private static func doctor() throws {
    let config = try Configuration.load()
    let executable = try currentExecutableURL()
    var failed = false
    check("configuration is root-owned and valid", true, &failed)
    check("GitHub host fixed to github.com", config.github.host == gitHubHost, &failed)
    check("broker responds for current UID", (try? BrokerClient.ping()) != nil, &failed)
    check("privileged broker is root-owned", protectedExecutable(Paths.privilegedBinary), &failed)
    check("protected GitHub CLI is root-owned", protectedExecutable(Paths.privilegedGH), &failed)
    check("gh wrapper installed", symlink(Paths.ghWrapper, targets: executable), &failed)
    check(
      "Git remote helper installed", symlink(Paths.gitRemoteWrapper, targets: executable),
      &failed)
    let rewrite = try runProcess(
      "/usr/bin/git",
      [
        "config", "--global", "--get-all",
        "url.agentauth::https://github.com/.insteadOf",
      ])
    check("GitHub HTTPS remotes use AgentAuth transport", rewrite.0 == 0, &failed)
    if failed { throw AppError.config("one or more doctor checks failed") }
  }

  private static func uninstall() throws {
    try PrivilegedService.invoke(["privileged-uninstall"])
    _ = try? runProcess(
      "/usr/bin/git",
      [
        "config", "--global", "--unset-all",
        "url.agentauth::https://github.com/.insteadOf",
      ])
    let executable = try currentExecutableURL()
    for wrapper in [Paths.ghWrapper, Paths.gitRemoteWrapper]
    where symlink(wrapper, targets: executable) { try FileManager.default.removeItem(at: wrapper) }
    try removeShellPathEntries()
    print("AgentAuth installation removed. Remove the GitHub App separately in GitHub settings.")
  }

  private static func removeShellPathEntries() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    for name in [".zprofile", ".bash_profile"] {
      let profile = home.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: profile.path) else { continue }
      let contents = try String(contentsOf: profile, encoding: .utf8)
      let updated = removingManagedPathBlock(from: contents)
      if updated != contents { try updated.write(to: profile, atomically: true, encoding: .utf8) }
    }
  }

  private static func gitRemoteHTTP() throws -> URL {
    let result = try runProcess("/usr/bin/git", ["--exec-path"])
    guard result.0 == 0,
      let path = String(data: result.1, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
    else {
      throw AppError.config("could not locate Git's HTTPS remote helper")
    }
    let binary = URL(fileURLWithPath: path).appendingPathComponent("git-remote-http")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
      throw AppError.config("Git HTTPS remote helper is not executable")
    }
    return binary.resolvingSymlinksInPath()
  }

  private static func requiredTool(_ name: String, excluding: URL?) throws -> URL {
    guard let path = commandPath(name, excluding: excluding) else {
      throw AppError.config("required tool not found: \(name)")
    }
    return path.resolvingSymlinksInPath()
  }
  private static func symlink(_ path: URL, targets target: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == target.path
  }
  private static func protectedExecutable(_ path: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
      let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
    else { return false }
    return permissions & 0o022 == 0 && FileManager.default.isExecutableFile(atPath: path.path)
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
  private static func option(_ name: String, _ arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
      return nil
    }
    return arguments[index + 1]
  }
  private static func requiredOption(_ name: String, _ arguments: [String]) throws -> String {
    guard let value = option(name, arguments) else {
      throw AppError.config("missing required option \(name)")
    }
    return value
  }
  private static func validateOptions(_ arguments: [String], allowed: Set<String>) throws {
    guard arguments.count.isMultiple(of: 2) else {
      throw AppError.config("every setup option requires a value")
    }
    var seen = Set<String>()
    for index in stride(from: 0, to: arguments.count, by: 2) {
      let name = arguments[index]
      guard allowed.contains(name) else { throw AppError.config("unknown setup option: \(name)") }
      guard seen.insert(name).inserted else {
        throw AppError.config("duplicate setup option: \(name)")
      }
    }
  }
  private static func printUsage() {
    print(
      """
      Usage:
        github-agent-auth setup --app-id ID --installation-id ID --private-key PATH
          [--repository OWNER/REPO] [--permissions core|developer]
        github-agent-auth install-service
        github-agent-auth update-gh
        github-agent-auth repo add|remove [--repository OWNER/REPO]
        github-agent-auth permissions [set core|developer]
        github-agent-auth context TYPE [--repository OWNER/REPO]
        github-agent-auth list|status|doctor|self-test
        github-agent-auth uninstall

      Create and install the private GitHub App manually, then run setup inside the first
      repository you want to authorize.
      """)
  }
}

func removingManagedPathBlock(from contents: String) -> String {
  contents.replacingOccurrences(
    of: "# Added by github-agent-auth\nexport PATH=\"$HOME/.local/bin:$PATH\"\n", with: "")
}
