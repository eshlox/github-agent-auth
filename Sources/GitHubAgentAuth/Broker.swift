import Darwin
import Foundation

enum BrokerOperation: String, Codable, Sendable {
  case gitCredential = "git_credential"
  case ghToken = "gh_token"
}
struct BrokerRequest: Codable, Sendable {
  let version: Int
  let operation: BrokerOperation
  let repository: String
}
struct BrokerResponse: Codable, Sendable {
  var username: String?, token: String?, expiresAt: String?, error: String?
  enum CodingKeys: String, CodingKey {
    case username, token
    case expiresAt = "expires_at"
    case error
  }
}

final class Broker: @unchecked Sendable {
  private let configuration: Configuration
  private let socketPath: String
  private var cache: [Repository: InstallationToken] = [:]
  private let cacheLock = NSLock()

  init(configuration: Configuration, socketPath: String = Paths.socket.path) {
    self.configuration = configuration
    self.socketPath = socketPath
  }

  func run() throws -> Never {
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if FileManager.default.fileExists(atPath: socketPath) {
      if (try? UnixSocket.connect(path: socketPath)) != nil {
        throw AppError.broker("another broker is already listening")
      }
      try FileManager.default.removeItem(atPath: socketPath)
    }
    let server = try UnixSocket.listen(path: socketPath)
    try setMode(socketPath, 0o600)
    while true {
      let client = Darwin.accept(server, nil, nil)
      guard client >= 0 else {
        if errno == EINTR { continue }
        throw AppError.system("accept", errno)
      }
      DispatchQueue.global().async { [self] in
        defer { Darwin.close(client) }
        do { try handle(client) } catch { fputs("broker: connection failed\n", stderr) }
      }
    }
  }

  private func handle(_ descriptor: Int32) throws {
    let data = try UnixSocket.readLine(descriptor, limit: 16 * 1024)
    let request = try JSONDecoder().decode(BrokerRequest.self, from: data)
    let response: BrokerResponse
    do {
      guard request.version == 1 else { throw AppError.broker("unsupported protocol version") }
      let repository = try Repository(request.repository)
      _ = try configuration.installationID(for: repository)
      let credential = try cachedToken(for: repository)
      response = BrokerResponse(
        username: request.operation == .gitCredential ? "x-access-token" : nil,
        token: credential.value, expiresAt: credential.expiresAt, error: nil
      )
    } catch {
      response = BrokerResponse(
        username: nil, token: nil, expiresAt: nil, error: error.localizedDescription)
    }
    var encoded = try JSONEncoder().encode(response)
    encoded.append(0x0A)
    try UnixSocket.writeAll(descriptor, encoded)
  }

  private func cachedToken(for repository: Repository) throws -> InstallationToken {
    cacheLock.lock()
    if let token = cache[repository], token.cacheUntil > Date().addingTimeInterval(30) {
      cacheLock.unlock()
      return token
    }
    cacheLock.unlock()
    let token = try blockingAsync {
      try await GitHubClient.mint(configuration: self.configuration, repository: repository)
    }
    cacheLock.lock()
    cache[repository] = token
    cacheLock.unlock()
    return token
  }

  static func request(_ request: BrokerRequest, socketPath: String = Paths.socket.path) throws
    -> BrokerResponse
  {
    let descriptor = try UnixSocket.connect(path: socketPath)
    defer { Darwin.close(descriptor) }
    var data = try JSONEncoder().encode(request)
    data.append(0x0A)
    try UnixSocket.writeAll(descriptor, data)
    let response = try JSONDecoder().decode(
      BrokerResponse.self, from: UnixSocket.readLine(descriptor, limit: 64 * 1024))
    if let error = response.error { throw AppError.broker(error) }
    return response
  }
}

enum UnixSocket {
  static func listen(path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw AppError.system("socket", errno) }
    do {
      var address = try makeAddress(path)
      let status = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(descriptor, $0, addressLength(path))
        }
      }
      guard status == 0 else { throw AppError.system("bind", errno) }
      guard Darwin.listen(descriptor, 64) == 0 else { throw AppError.system("listen", errno) }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  static func connect(path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw AppError.system("socket", errno) }
    var address = try makeAddress(path)
    let status = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, addressLength(path))
      }
    }
    guard status == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw AppError.system("connect", code)
    }
    return descriptor
  }

  static func readLine(_ descriptor: Int32, limit: Int) throws -> Data {
    var result = Data()
    var byte: UInt8 = 0
    while result.count < limit {
      let count = Darwin.read(descriptor, &byte, 1)
      if count == 0 { break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw AppError.system("read", errno)
      }
      if byte == 0x0A { return result }
      result.append(byte)
    }
    guard result.count < limit else { throw AppError.broker("message too large") }
    return result
  }

  static func writeAll(_ descriptor: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
      var sent = 0
      while sent < raw.count {
        let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: sent), raw.count - sent)
        guard count >= 0 else {
          if errno == EINTR { continue }
          throw AppError.system("write", errno)
        }
        sent += count
      }
    }
  }

  private static func makeAddress(_ path: String) throws -> sockaddr_un {
    let bytes = path.utf8CString
    guard bytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      throw AppError.broker("socket path is too long")
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
        for index in bytes.indices { destination[index] = bytes[index] }
      }
    }
    return address
  }

  private static func addressLength(_ path: String) -> socklen_t {
    socklen_t(MemoryLayout<sa_family_t>.size + path.utf8CString.count)
  }
}
