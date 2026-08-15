import Foundation

enum SelfTest {
  static func run() throws {
    var count = 0
    try expect(service == "net.eshlox.github-agent-auth", "stable service identifier", &count)
    try expect(
      Repository("Org-A/FrontEnd.git") == Repository("org-a/frontend"), "repository normalization",
      &count)
    for value in [
      "../frontend", "org/frontend/extra", "org/../../infra", "org/", "/repo", "org/repo?x=y",
    ] {
      try expectFailure("reject repository \(value)", &count) { _ = try Repository(value) }
    }
    _ = try GitIntegration.repository(remote: "https://github.com/org/repo.git")
    count += 1
    for url in [
      "http://github.com/org/repo", "https://attacker.example/org/repo",
      "https://github.com.attacker.example/org/repo",
      "https://github.com@attacker.example/org/repo",
      "https://user@github.com/org/repo", "git@github.com:org/repo.git",
    ] {
      try expectFailure("reject remote \(url)", &count) {
        _ = try GitIntegration.repository(remote: url)
      }
    }
    let config = Configuration(
      allowedUID: 501, allowedGID: 20, workerUID: 499, workerGID: 499,
      github: .init(host: gitHubHost, appID: 1),
      installations: [.init(owner: "Org-A", installationID: 42, repositories: ["FrontEnd"])],
      tooling: .init(
        ghBinary: "/usr/local/bin/gh", gitRemoteHTTPBinary: "/usr/libexec/git-remote-http"))
    try expect(
      try config.installationID(for: Repository("org-a/frontend")) == 42, "exact allowlist match",
      &count)
    try expectFailure("deny unlisted repository", &count) {
      _ = try config.installationID(for: Repository("org-a/infra"))
    }
    try expectFailure("deny different owner", &count) {
      _ = try config.installationID(for: Repository("org-b/frontend"))
    }
    try expect(apiBase.absoluteString == "https://api.github.com", "fixed API origin", &count)
    try expect(
      projectURL == "https://github.com/eshlox/github-agent-auth", "fixed project URL", &count)
    try expect(
      PermissionProfile.core.permissions == [
        "contents": "write", "pull_requests": "write", "metadata": "read",
      ], "core permission profile", &count)
    try expect(
      try PermissionProfile.setupValue(nil) == .core, "secure setup permission default", &count)
    try expectFailure("reject invalid setup permission profile", &count) {
      _ = try PermissionProfile.setupValue("unrestricted")
    }
    let ciPermissions = PermissionProfile.ciRead.permissions
    try expect(
      ciPermissions["actions"] == "read" && ciPermissions["checks"] == "read"
        && ciPermissions["statuses"] == "read", "CI permissions are read-only", &count)
    for deniedPermission in [
      "administration", "workflows", "deployments", "environments", "secrets",
    ] {
      try expect(ciPermissions[deniedPermission] == nil, "exclude \(deniedPermission)", &count)
    }
    for command in [
      ["pr", "list"], ["pr", "view", "12"],
      ["pr", "create", "--head", "agent/test", "--title", "Title", "--body", "Body"],
    ] {
      _ = try CommandPolicy.validateGH(command)
      count += 1
    }
    for command in [
      ["api", "user"], ["pr", "merge", "12"], ["extension", "exec", "attacker/tool"],
      ["alias", "set", "leak", "!env"], ["pr", "create", "--fill"],
      ["pr", "comment", "12", "--body-file", "/etc/master.passwd"],
    ] {
      try expectFailure("reject gh command \(command.joined(separator: " "))", &count) {
        _ = try CommandPolicy.validateGH(command)
      }
    }
    let server = try LoopbackHTTPServer()
    let wrongURL = server.baseURL.appending(path: "callback").appending(queryItems: [
      URLQueryItem(name: "state", value: "wrong")
    ])
    let expectedURL = server.baseURL.appending(path: "callback").appending(queryItems: [
      URLQueryItem(name: "state", value: "expected")
    ])
    DispatchQueue.global().async {
      _ = try? Data(contentsOf: wrongURL)
      _ = try? Data(contentsOf: expectedURL)
    }
    let callback = try server.waitForRequest(
      timeout: 3,
      matching: {
        $0.path == "/callback" && $0.query["state"] == "expected"
      },
      handler: { _ in "ok" })
    try expect(callback.query["state"] == "expected", "loopback callback state", &count)
    print("Self-test passed: \(count) security checks")
  }

  private static func expect(
    _ condition: @autoclosure () throws -> Bool, _ name: String, _ count: inout Int
  ) throws {
    guard try condition() else { throw AppError.config("self-test failed: \(name)") }
    count += 1
  }
  private static func expectFailure(
    _ name: String, _ count: inout Int, operation: () throws -> Void
  ) throws {
    var rejected = false
    do { try operation() } catch { rejected = true }
    guard rejected else { throw AppError.config("self-test failed: \(name)") }
    count += 1
  }
}
