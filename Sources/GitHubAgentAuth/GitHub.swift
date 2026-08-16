import Foundation
import Security

struct InstallationToken: Sendable {
  let value: String, expiresAt: String, cacheUntil: Date
}

let safeSession = URLSession(
  configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)

func validate(response: URLResponse, data: Data, operation: String) throws {
  guard let http = response as? HTTPURLResponse else {
    throw AppError.github("\(operation) returned a non-HTTP response")
  }
  guard ![301, 302, 303, 307, 308].contains(http.statusCode) else {
    throw AppError.github("\(operation) redirect refused")
  }
  guard (200..<300).contains(http.statusCode) else {
    throw AppError.github("\(operation) failed with HTTP \(http.statusCode)")
  }
  guard data.count <= 65_536 else { throw AppError.github("\(operation) response exceeded 64 KiB") }
}

enum GitHubClient {
  private struct Claims: Encodable { let iat: Int, exp: Int, iss: String }
  private struct TokenRequest: Encodable {
    let repositories: [String]
    let permissions: [String: String]
  }
  private struct TokenResponse: Decodable {
    let token: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
      case token
      case expiresAt = "expires_at"
    }
  }
  private struct InstallationResponse: Decodable {
    struct Account: Decodable { let login: String }
    let account: Account
  }

  static func mint(configuration: Configuration, repository: Repository) async throws
    -> InstallationToken
  {
    let installationID = try configuration.installationID(for: repository)
    guard configuration.github.host == gitHubHost else {
      throw AppError.denied("unsupported GitHub host")
    }
    let pem = try SecretStore.load()
    let jwt = try makeJWT(appID: configuration.github.appID, pem: pem)
    let url = apiBase.appending(path: "app/installations/\(installationID)/access_tokens")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("AgentAuth-for-GitHub", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    guard let name = configuration.permissionProfile,
      let permissions = PermissionProfile(rawValue: name)?.permissions
    else { throw AppError.config("permission profile must be core or developer") }
    request.httpBody = try JSONEncoder().encode(
      TokenRequest(
        repositories: [repository.name], permissions: permissions
      ))

    let (body, response) = try await safeSession.data(for: request)
    try validate(response: response, data: body, operation: "token request")
    let decoded = try JSONDecoder().decode(TokenResponse.self, from: body)
    guard !decoded.token.isEmpty else { throw AppError.github("GitHub returned an empty token") }
    return InstallationToken(
      value: decoded.token, expiresAt: decoded.expiresAt,
      cacheUntil: Date().addingTimeInterval(50 * 60))
  }

  static func verifyInstallation(
    appID: UInt64, pem: Data, installationID: UInt64,
    repository: Repository, profile: PermissionProfile
  ) async throws -> VerifiedInstallation {
    let jwt = try makeJWT(appID: appID, pem: pem)
    var installationRequest = URLRequest(
      url: apiBase.appending(path: "app/installations/\(installationID)"))
    installationRequest.timeoutInterval = 30
    addAppHeaders(to: &installationRequest, jwt: jwt)
    let (installationData, installationResponse) = try await safeSession.data(
      for: installationRequest)
    try validate(
      response: installationResponse, data: installationData, operation: "installation verification"
    )
    let installation = try JSONDecoder().decode(InstallationResponse.self, from: installationData)
    guard installation.account.login.caseInsensitiveCompare(repository.owner) == .orderedSame else {
      throw AppError.denied(
        "installation belongs to \(installation.account.login), not \(repository.owner)")
    }

    var tokenRequest = URLRequest(
      url: apiBase.appending(path: "app/installations/\(installationID)/access_tokens"))
    tokenRequest.httpMethod = "POST"
    tokenRequest.timeoutInterval = 30
    addAppHeaders(to: &tokenRequest, jwt: jwt)
    tokenRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    tokenRequest.httpBody = try JSONEncoder().encode(
      TokenRequest(
        repositories: [repository.name], permissions: profile.permissions
      ))
    let (tokenData, tokenResponse) = try await safeSession.data(for: tokenRequest)
    try validate(
      response: tokenResponse, data: tokenData, operation: "repository access verification")
    let token = try JSONDecoder().decode(TokenResponse.self, from: tokenData)
    guard !token.token.isEmpty else {
      throw AppError.github("repository verification returned an empty token")
    }
    return VerifiedInstallation(id: installationID, owner: installation.account.login)
  }

  private static func addAppHeaders(to request: inout URLRequest, jwt: String) {
    request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("AgentAuth-for-GitHub", forHTTPHeaderField: "User-Agent")
  }

  static func makeJWT(appID: UInt64, pem: Data, now: Date = Date()) throws -> String {
    let key = try privateKey(pem)
    let encoder = JSONEncoder()
    let header = try encoder.encode(["alg": "RS256", "typ": "JWT"]).base64URL
    let epoch = Int(now.timeIntervalSince1970)
    let payload = try encoder.encode(
      Claims(iat: epoch - 60, exp: epoch + 9 * 60, iss: String(appID))
    ).base64URL
    let signingInput = Data("\(header).\(payload)".utf8)
    var error: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(
        key, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, &error) as Data?
    else {
      throw AppError.cryptography(
        error?.takeRetainedValue().localizedDescription ?? "RSA signing failed")
    }
    return "\(header).\(payload).\(signature.base64URL)"
  }

  private static func privateKey(_ pem: Data) throws -> SecKey {
    guard let string = String(data: pem, encoding: .utf8),
      let begin = string.range(of: "-----BEGIN RSA PRIVATE KEY-----"),
      let end = string.range(of: "-----END RSA PRIVATE KEY-----")
    else {
      throw AppError.cryptography("expected a PKCS#1 RSA private key PEM")
    }
    let encoded = string[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
    guard let der = Data(base64Encoded: String(encoded)) else {
      throw AppError.cryptography("invalid PEM encoding")
    }
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
      throw AppError.cryptography(
        error?.takeRetainedValue().localizedDescription ?? "invalid RSA key")
    }
    return key
  }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
