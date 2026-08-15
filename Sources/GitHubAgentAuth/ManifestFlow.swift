import Foundation
import Security

enum PermissionProfile: String, CaseIterable {
  case core
  case ciRead = "ci-read"

  var permissions: [String: String] {
    var values = ["contents": "write", "pull_requests": "write", "metadata": "read"]
    if self == .ciRead {
      values["actions"] = "read"
      values["checks"] = "read"
      values["statuses"] = "read"
    }
    return values
  }

  var summary: String {
    self == .core
      ? "Contents RW, pull requests RW, metadata R"
      : "Contents RW, pull requests RW, actions/checks/statuses R, metadata R"
  }

  static func setupValue(_ value: String?) throws -> Self {
    let name = value ?? Self.core.rawValue
    guard let profile = Self(rawValue: name) else {
      throw AppError.config("--permissions must be core or ci-read")
    }
    return profile
  }
}

struct ManifestApp: Decodable, Sendable {
  let id: UInt64
  let pem: String
  let slug: String
}

struct VerifiedInstallation: Sendable {
  let id: UInt64
  let owner: String
}

enum ManifestFlow {
  static func createApp(
    for repository: Repository, profile: PermissionProfile,
    organization: String?
  ) throws -> (ManifestApp, VerifiedInstallation) {
    let server = try LoopbackHTTPServer()
    let state = try randomHex(byteCount: 32)
    let callbackURL = server.baseURL.appending(path: "manifest-callback")
    let setupURL = server.baseURL.appending(path: "installation-callback").appending(queryItems: [
      URLQueryItem(name: "state", value: state)
    ])
    let manifest = try makeManifest(profile: profile, callbackURL: callbackURL, setupURL: setupURL)
    let startPage = try makeStartPage(manifest: manifest, state: state, organization: organization)

    let startPath = "/start/\(state)"
    print("Opening GitHub to create the preconfigured App…")
    try openURL(server.baseURL.appending(path: startPath))
    let callback = try server.waitForRequest(
      timeout: 10 * 60,
      matching: {
        $0.path == "/manifest-callback" && $0.query["state"] == state && $0.query["code"] != nil
      },
      handler: { request in
        request.path == startPath
          ? startPage : confirmationPage("GitHub App created. Return to Terminal.")
      })
    guard let code = callback.query["code"], !code.isEmpty else {
      throw AppError.denied("GitHub manifest callback code was missing")
    }
    let app = try blockingAsync { try await convert(code: code) }
    try Repository.validate(app.slug)

    print("Opening GitHub to select repositories and install the App…")
    try openURL(URL(string: "https://github.com/apps/\(app.slug)/installations/new")!)
    let installationCallback = try server.waitForRequest(
      timeout: 10 * 60,
      matching: {
        $0.path == "/installation-callback" && $0.query["state"] == state
          && $0.query["installation_id"] != nil
      },
      handler: { request in
        confirmationPage(
          request.path == "/installation-callback"
            ? "Installation received. Return to Terminal." : "Waiting for installation…")
      })
    guard let rawID = installationCallback.query["installation_id"],
      let installationID = UInt64(rawID)
    else {
      throw AppError.denied("GitHub did not provide a valid installation ID")
    }
    let installation = try blockingAsync {
      try await GitHubClient.verifyInstallation(
        appID: app.id, pem: Data(app.pem.utf8), installationID: installationID,
        repository: repository, profile: profile
      )
    }
    return (app, installation)
  }

  private static func makeManifest(profile: PermissionProfile, callbackURL: URL, setupURL: URL)
    throws -> String
  {
    let host = Host.current().localizedName?.replacingOccurrences(of: " ", with: "-") ?? "Mac"
    let suffix = try randomHex(byteCount: 4)
    let value: [String: Any] = [
      "name": "AgentAuth for GitHub - \(host.prefix(10)) \(suffix)",
      "url": projectURL,
      "description": "Repository-scoped GitHub credentials for local development agents",
      "redirect_url": callbackURL.absoluteString,
      "setup_url": setupURL.absoluteString,
      "setup_on_update": false,
      "public": false,
      "request_oauth_on_install": false,
      "hook_attributes": ["url": "https://example.invalid/disabled", "active": false],
      "default_events": [],
      "default_permissions": profile.permissions,
    ]
    return String(
      data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
      encoding: .utf8)!
  }

  private static func makeStartPage(manifest: String, state: String, organization: String?) throws
    -> String
  {
    let action: String
    if let organization {
      try Repository.validate(organization)
      action = "https://github.com/organizations/\(organization)/settings/apps/new?state=\(state)"
    } else {
      action = "https://github.com/settings/apps/new?state=\(state)"
    }
    return """
      <!doctype html><meta charset="utf-8"><title>AgentAuth for GitHub Setup</title>
      <p>Redirecting to GitHub…</p>
      <form id="manifest" method="post" action="\(action)">
        <input type="hidden" name="manifest" value="\(htmlEscape(manifest))">
      </form><script>document.getElementById('manifest').submit()</script>
      """
  }

  private static func convert(code: String) async throws -> ManifestApp {
    guard code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), code.count <= 128 else {
      throw AppError.denied("invalid manifest conversion code")
    }
    var request = URLRequest(url: apiBase.appending(path: "app-manifests/\(code)/conversions"))
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("AgentAuth-for-GitHub/0.2.0", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await safeSession.data(for: request)
    try validate(response: response, data: data, operation: "manifest conversion")
    return try JSONDecoder().decode(ManifestApp.self, from: data)
  }

  private static func randomHex(byteCount: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw AppError.config("secure random generation failed")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func confirmationPage(_ message: String) -> String {
    "<!doctype html><meta charset=\"utf-8\"><title>AgentAuth for GitHub</title><h1>\(message)</h1><p>You can close this tab.</p>"
  }

  private static func htmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(
      of: "\"", with: "&quot;"
    )
    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
  }
}
