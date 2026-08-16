import Darwin
import XCTest

@testable import GitHubAgentAuth

final class SecurityTests: XCTestCase {
  func testRepositoryAllowlistIsExact() throws {
    let config = configuration()
    XCTAssertEqual(try config.installationID(for: Repository("owner/repository")), 42)
    XCTAssertThrowsError(try config.installationID(for: Repository("owner/other")))
    XCTAssertThrowsError(try config.installationID(for: Repository("other/repository")))
  }

  func testRemoteParsingAcceptsOnlyGitHubHTTPS() throws {
    XCTAssertEqual(
      try GitIntegration.repository(remote: "https://github.com/owner/repository.git"),
      try Repository("owner/repository"))
    XCTAssertEqual(
      try GitIntegration.repository(remote: "agentauth::https://github.com/owner/repository.git"),
      try Repository("owner/repository"))
    for remote in [
      "http://github.com/owner/repository", "https://attacker.example/owner/repository",
      "https://github.com.attacker.example/owner/repository",
      "https://github.com@attacker.example/owner/repository", "git@github.com:owner/repository",
    ] {
      XCTAssertThrowsError(try GitIntegration.repository(remote: remote), remote)
    }
  }

  func testGHPolicyAllowsDocumentedCommands() throws {
    XCTAssertEqual(try CommandPolicy.validateGH(["pr", "list"]), "pr_list")
    XCTAssertEqual(
      try CommandPolicy.validateGH([
        "pr", "create", "--head", "agent/change", "--title", "Title", "--body", "Body",
      ]), "pr_create")
    XCTAssertEqual(
      try CommandPolicy.validateGH(["issue", "create", "--title", "Title", "--body", "Body"]),
      "issue_create")
    XCTAssertEqual(
      try CommandPolicy.validateGH(["issue", "comment", "12", "--body", "Body"]),
      "issue_comment")
  }

  func testGHPolicyRejectsCredentialEscapeSurfaces() {
    for arguments in [
      ["api", "user"], ["alias", "set", "leak", "!env"],
      ["extension", "exec", "attacker/tool"], ["pr", "merge", "12"],
      ["pr", "comment", "12", "--body-file", "/etc/master.passwd"],
      ["pr", "create", "--template", "/etc/master.passwd"],
      ["pr", "close", "12", "--delete-branch"],
      ["pr", "list", "-Rattacker/repository"],
      ["pr", "list", "--", "--repo", "attacker/repository"],
      ["issue", "create", "--title", "Title", "--body-file", "/etc/master.passwd"],
      ["issue", "create", "--title", "Title", "--body", "Body", "--label", "approved"],
      ["issue", "comment", "12", "--body", "Body", "--edit-last"],
      ["issue", "close", "12", "--reason", "not planned"],
    ] {
      XCTAssertThrowsError(
        try CommandPolicy.validateGH(arguments), arguments.joined(separator: " "))
    }
  }

  func testDeveloperContextUsesOnlyFixedGitHubAPIRequests() throws {
    let repository = try Repository("owner/repository")
    for kind in ContextKind.allCases {
      let arguments = kind.ghArguments(repository: repository)
      XCTAssertEqual(arguments.first, "api")
      XCTAssertFalse(arguments.contains("--input"))
      XCTAssertFalse(arguments.contains("--raw-field"))
      if arguments.dropFirst().first == "graphql" {
        XCTAssertTrue(arguments.contains(where: { $0.hasPrefix("query=query(") }))
        XCTAssertFalse(arguments.contains(where: { $0.contains("mutation") }))
      } else {
        XCTAssertEqual(Array(arguments.prefix(3)), ["api", "--method", "GET"])
      }
      XCTAssertTrue(arguments.joined(separator: " ").contains("owner"))
      XCTAssertTrue(arguments.joined(separator: " ").contains("repository"))
    }
  }

  func testConfigurationRejectsRootClientAndRelativeTools() {
    var config = configuration()
    config.allowedUID = 0
    XCTAssertThrowsError(try config.validate())
    config = configuration()
    config.tooling.ghBinary = "gh"
    XCTAssertThrowsError(try config.validate())
    config = configuration()
    config.workerUID = config.allowedUID
    XCTAssertThrowsError(try config.validate())
    config = configuration()
    config.permissionProfile = nil
    XCTAssertThrowsError(try config.validate())
    config = configuration()
    config.permissionProfile = "ci-read"
    XCTAssertThrowsError(try config.validate())
  }

  func testStreamFramingPreservesBinaryPayload() throws {
    var descriptors: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
    defer {
      close(descriptors[0])
      close(descriptors[1])
    }
    let payload = Data((0..<1024).map { UInt8($0 % 251) })
    try sendFrame(.standardInput, payload, to: descriptors[0])
    let frame = try XCTUnwrap(readFrame(from: descriptors[1]))
    XCTAssertEqual(frame.0, .standardInput)
    XCTAssertEqual(frame.1, payload)
  }

  func testBrokerAcceptsOnlyStatelessGitTransport() throws {
    var validator = InputValidator(.gitStateless)
    XCTAssertEqual(try validator.validate(Data("capabilities\n".utf8)), Data("capabilities\n".utf8))
    XCTAssertEqual(
      try validator.validate(Data("stateless-connect git-upload-pack\n0000".utf8)),
      Data("stateless-connect git-upload-pack\n0000".utf8))
    XCTAssertNoThrow(try validator.validateClose())

    var legacy = InputValidator(.gitStateless)
    XCTAssertThrowsError(try legacy.validate(Data("capabilities\npush refs/heads/main\n".utf8)))
    var arbitrary = InputValidator(.closed)
    XCTAssertThrowsError(try arbitrary.validate(Data("secret input".utf8)))
  }

  func testUninstallRemovesEveryPrivilegedArtifact() {
    XCTAssertEqual(
      Set(PrivilegedService.privilegedArtifactPaths),
      Set([Paths.launchDaemon, Paths.socket, Paths.auditLog, Paths.daemonLog]))
    XCTAssertEqual(
      Set(PrivilegedService.privilegedDirectoryPaths),
      Set([
        Paths.isolatedGHDirectory, Paths.privateTemporaryDirectory, Paths.systemDirectory,
        Paths.socketDirectory,
      ]))
  }

  func testUninstallRemovesOnlyManagedShellPathBlock() {
    let profile =
      "export EDITOR=vim\n# Added by github-agent-auth\n"
      + "export PATH=\"$HOME/.local/bin:$PATH\"\nexport LANG=en_US.UTF-8\n"
    XCTAssertEqual(
      removingManagedPathBlock(from: profile),
      "export EDITOR=vim\nexport LANG=en_US.UTF-8\n")
  }

  func testReleaseScriptsBypassRestrictedGitHubCLIShim() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    for name in ["release-local.sh", "publish-homebrew-formula.sh"] {
      let script = try String(
        contentsOf: root.appendingPathComponent("scripts/\(name)"), encoding: .utf8)
      XCTAssertTrue(script.contains("RELEASE_GH"), name)
      XCTAssertFalse(script.contains("\ngh "), name)
    }
  }

  func testSourceInstallerDoesNotDownloadAsRoot() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let script = try String(contentsOf: root.appendingPathComponent("install.sh"), encoding: .utf8)
    XCTAssertTrue(script.contains("GITHUB_AGENT_AUTH_REF"))
    XCTAssertTrue(script.contains("codesign --verify --strict"))
    XCTAssertTrue(script.contains("self-test"))
    XCTAssertFalse(script.contains("sudo"))
    XCTAssertFalse(script.contains("curl"))
  }

  func testProjectURLMatchesRepository() {
    XCTAssertEqual(projectURL, "https://github.com/eshlox/github-agent-auth")
  }

  private func configuration() -> Configuration {
    Configuration(
      allowedUID: 501, allowedGID: 20, workerUID: 499, workerGID: 499,
      github: .init(host: gitHubHost, appID: 1),
      installations: [.init(owner: "owner", installationID: 42, repositories: ["repository"])],
      tooling: .init(
        ghBinary: "/Library/PrivilegedHelperTools/agentauth-gh",
        gitRemoteHTTPBinary: "/usr/libexec/git-core/git-remote-http"),
      permissionProfile: PermissionProfile.core.rawValue)
  }
}
