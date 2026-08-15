import Darwin
import Foundation

enum BrokerOperation: String, Codable, Sendable {
  case gitRemote = "git_remote"
  case ghCommand = "gh_command"
  case ping
}
struct BrokerRequest: Codable, Sendable {
  let version: Int
  let operation: BrokerOperation
  let repository: String?
  let arguments: [String]
}
enum StreamChannel: UInt8 {
  case standardInput = 1
  case inputClosed, standardOutput, standardError, exit
}

enum BrokerInputPolicy { case gitStateless, closed }

struct InputValidator {
  private let policy: BrokerInputPolicy
  private var gitLine = Data()
  private var gitStep = 0

  init(_ policy: BrokerInputPolicy) { self.policy = policy }

  mutating func validate(_ data: Data) throws -> Data {
    guard policy == .gitStateless else { throw AppError.denied("command does not accept stdin") }
    guard gitStep < 2 else { return data }
    gitLine.append(data)
    guard gitLine.count <= 1024 else { throw AppError.denied("Git transport command is too long") }
    var validated = Data()
    while gitStep < 2, let newline = gitLine.firstIndex(of: 0x0A) {
      let command = String(data: gitLine[gitLine.startIndex..<newline], encoding: .utf8)
      if gitStep == 0 {
        guard command == "capabilities" else {
          throw AppError.denied("Git transport must begin with capabilities negotiation")
        }
      } else {
        guard
          command == "stateless-connect git-upload-pack"
            || command == "stateless-connect git-receive-pack"
        else { throw AppError.denied("Git transport requires stateless-connect") }
      }
      let end = gitLine.index(after: newline)
      validated.append(gitLine[..<end])
      gitLine.removeSubrange(..<end)
      gitStep += 1
    }
    if gitStep == 2 {
      validated.append(gitLine)
      gitLine.removeAll(keepingCapacity: false)
    }
    return validated
  }

  func validateClose() throws {
    if policy == .gitStateless, gitStep < 2 {
      throw AppError.denied("Git transport closed before stateless-connect")
    }
  }
}

private final class RelayErrorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Error?
  func store(_ error: Error) { lock.withLock { value = error } }
  func load() -> Error? { lock.withLock { value } }
}

enum CommandPolicy {
  private static let allowedGHCommands: Set<String> = [
    "pr checks", "pr close", "pr comment", "pr create", "pr diff", "pr list", "pr ready",
    "pr reopen", "pr review", "pr status", "pr view", "repo view",
  ]
  private static let forbiddenFlags: Set<String> = [
    "--body-file", "--editor", "--fill", "--fill-first", "--fill-verbose", "--head-file",
    "--hostname", "--recover", "--repo", "--template", "--delete-branch", "--verbose", "--debug",
    "-F", "-R", "--web",
  ]

  static func validateGH(_ arguments: [String]) throws -> String {
    guard arguments.count >= 2 else { throw AppError.denied("unsupported gh command") }
    let command = "\(arguments[0]) \(arguments[1])"
    guard allowedGHCommands.contains(command) else {
      throw AppError.denied("gh command is not allowlisted: \(command)")
    }
    for argument in arguments {
      let flag = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
      guard !forbiddenFlags.contains(flag), !argument.hasPrefix("-R"), argument != "--" else {
        throw AppError.denied("gh flag is not allowed: \(flag)")
      }
    }
    if command == "pr create" {
      for required in ["--head", "--title", "--body"] where !arguments.contains(required) {
        throw AppError.denied("gh pr create requires \(required)")
      }
    }
    return command.replacingOccurrences(of: " ", with: "_")
  }
}

final class Broker: @unchecked Sendable {
  private let configuration: Configuration
  private let socketPath: String
  private var cache: [Repository: InstallationToken] = [:]
  private let cacheLock = NSLock()
  private let auditLock = NSLock()

  init(configuration: Configuration, socketPath: String = Paths.socket.path) {
    self.configuration = configuration
    self.socketPath = socketPath
  }

  func run() throws -> Never {
    guard geteuid() == 0 else { throw AppError.denied("broker daemon must run as root") }
    let worker = try brokerWorkerIdentity()
    guard worker.uid == configuration.workerUID, worker.gid == configuration.workerGID else {
      throw AppError.denied("broker service account identity changed")
    }
    try validateBrokerTool(configuration.tooling.ghBinary)
    try validateBrokerTool(configuration.tooling.gitRemoteHTTPBinary)
    try validateBrokerTool("/usr/bin/sudo")
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    if FileManager.default.fileExists(atPath: socketPath) {
      try FileManager.default.removeItem(atPath: socketPath)
    }
    let server = try UnixSocket.listen(path: socketPath)
    guard chown(socketPath, 0, configuration.allowedGID) == 0 else {
      throw AppError.system("chown broker socket", errno)
    }
    try setMode(socketPath, 0o660)
    while true {
      let client = Darwin.accept(server, nil, nil)
      guard client >= 0 else {
        if errno == EINTR { continue }
        throw AppError.system("accept", errno)
      }
      DispatchQueue.global().async { [self] in
        defer { Darwin.close(client) }
        do { try handle(client) } catch { try? sendError(error.localizedDescription, to: client) }
      }
    }
  }

  private func handle(_ descriptor: Int32) throws {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(descriptor, &uid, &gid) == 0, uid == configuration.allowedUID else {
      throw AppError.denied("socket client identity is not authorized")
    }
    let request = try JSONDecoder().decode(
      BrokerRequest.self, from: UnixSocket.readLine(descriptor, limit: 64 * 1024))
    guard request.version == 1 else { throw AppError.broker("unsupported protocol version") }
    if request.operation == .ping {
      try sendFrame(.exit, Data("0".utf8), to: descriptor)
      return
    }
    guard let rawRepository = request.repository else {
      throw AppError.denied("repository is required")
    }
    let repository = try Repository(rawRepository)
    var operation = request.operation.rawValue
    do {
      if request.operation == .ghCommand {
        operation = try CommandPolicy.validateGH(request.arguments)
      } else if request.operation == .gitRemote {
        operation = "git_transport"
      }
      _ = try configuration.installationID(for: repository)
      let token = try cachedToken(for: repository).value
      try audit(uid: uid, repository: repository, operation: operation, decision: "allow")
      switch request.operation {
      case .gitRemote:
        try execute(
          executable: configuration.tooling.gitRemoteHTTPBinary,
          arguments: [repository.description, "https://github.com/\(repository.description).git"],
          environment: gitEnvironment(token: token), inputPolicy: .gitStateless,
          descriptor: descriptor)
      case .ghCommand:
        try execute(
          executable: configuration.tooling.ghBinary,
          arguments: request.arguments + ["--repo", repository.description],
          environment: ghEnvironment(token: token), inputPolicy: .closed, descriptor: descriptor)
      case .ping: break
      }
    } catch {
      try? audit(uid: uid, repository: repository, operation: operation, decision: "deny")
      throw error
    }
  }

  private func execute(
    executable: String, arguments: [String], environment: [String: String],
    inputPolicy: BrokerInputPolicy, descriptor: Int32
  ) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = ["-n", "-E", "-u", serviceAccount, "--", executable] + arguments
    process.environment = environment
    process.currentDirectoryURL = URL(fileURLWithPath: "/var/empty")
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    try process.run()

    let writeLock = NSLock()
    let group = DispatchGroup()
    let relayError = RelayErrorBox()
    for (handle, channel) in [
      (output.fileHandleForReading, StreamChannel.standardOutput),
      (error.fileHandleForReading, StreamChannel.standardError),
    ] {
      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        while true {
          let data = handle.readData(ofLength: 16 * 1024)
          if data.isEmpty { return }
          writeLock.lock()
          try? sendFrame(channel, data, to: descriptor)
          writeLock.unlock()
        }
      }
    }
    group.enter()
    DispatchQueue.global().async {
      var validator = InputValidator(inputPolicy)
      defer {
        group.leave()
        try? input.fileHandleForWriting.close()
      }
      do {
        while let frame = try readFrame(from: descriptor) {
          if frame.0 == .inputClosed {
            try validator.validateClose()
            return
          }
          guard frame.0 == .standardInput else { throw AppError.broker("invalid input frame") }
          let validated = try validator.validate(frame.1)
          if !validated.isEmpty {
            try input.fileHandleForWriting.write(contentsOf: validated)
          }
        }
      } catch {
        relayError.store(error)
        process.terminate()
      }
    }
    process.waitUntilExit()
    try? input.fileHandleForWriting.close()
    Darwin.shutdown(descriptor, SHUT_RD)
    group.wait()
    if let error = relayError.load() { throw error }
    try sendFrame(.exit, Data(String(process.terminationStatus).utf8), to: descriptor)
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

  private func gitEnvironment(token: String) -> [String: String] {
    let credential = Data("x-access-token:\(token)".utf8).base64EncodedString()
    return [
      "GIT_CONFIG_COUNT": "3", "GIT_CONFIG_KEY_0": "http.extraHeader",
      "GIT_CONFIG_VALUE_0": "Authorization: Basic \(credential)",
      "GIT_CONFIG_KEY_1": "credential.helper", "GIT_CONFIG_VALUE_1": "",
      "GIT_CONFIG_KEY_2": "http.followRedirects", "GIT_CONFIG_VALUE_2": "false",
      "GIT_DIR": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "HOME": "/var/empty",
      "PATH": "/usr/bin:/bin", "TMPDIR": Paths.privateTemporaryDirectory.path,
    ]
  }

  private func ghEnvironment(token: String) -> [String: String] {
    [
      "GH_CONFIG_DIR": Paths.isolatedGHDirectory.path, "GH_HOST": gitHubHost,
      "GH_PROMPT_DISABLED": "1", "GH_TOKEN": token, "HOME": "/var/empty",
      "PATH": "/usr/bin:/bin", "TMPDIR": Paths.privateTemporaryDirectory.path,
    ]
  }

  private func audit(uid: uid_t, repository: Repository, operation: String, decision: String) throws
  {
    auditLock.lock()
    defer { auditLock.unlock() }
    let record: [String: Any] = [
      "timestamp": ISO8601DateFormatter().string(from: Date()), "uid": uid,
      "repository": repository.description, "operation": operation, "decision": decision,
    ]
    var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    data.append(0x0A)
    if !FileManager.default.fileExists(atPath: Paths.auditLog.path) {
      FileManager.default.createFile(
        atPath: Paths.auditLog.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    let handle = try FileHandle(forWritingTo: Paths.auditLog)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  private func validateBrokerTool(_ path: String) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
      ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o022 == 0,
      FileManager.default.isExecutableFile(atPath: path)
    else { throw AppError.denied("broker tool is not root-owned and immutable to clients") }
  }
}

enum BrokerClient {
  static func runGH(repository: Repository, arguments: [String]) throws -> Never {
    let descriptor = try connect(
      .init(
        version: 1, operation: .ghCommand, repository: repository.description, arguments: arguments)
    )
    try sendFrame(.inputClosed, Data(), to: descriptor)
    let status = try relayOutput(descriptor)
    Darwin.close(descriptor)
    exit(status)
  }

  static func runGitRemote(repository: Repository, remoteName: String) throws -> Never {
    let descriptor = try connect(
      .init(
        version: 1, operation: .gitRemote, repository: repository.description,
        arguments: [remoteName]))
    guard readLine() == "capabilities" else {
      throw AppError.denied("git remote helper expected capabilities negotiation")
    }
    try sendFrame(.standardInput, Data("capabilities\n".utf8), to: descriptor)
    try discardRemoteCapabilities(descriptor)
    print("stateless-connect\n")
    DispatchQueue.global().async {
      while true {
        do {
          guard let data = try FileHandle.standardInput.read(upToCount: 16 * 1024), !data.isEmpty
          else { break }
          try sendFrame(.standardInput, data, to: descriptor)
        } catch { break }
      }
      try? sendFrame(.inputClosed, Data(), to: descriptor)
    }
    let status = try relayOutput(descriptor)
    Darwin.close(descriptor)
    exit(status)
  }

  static func ping() throws {
    let descriptor = try connect(
      .init(
        version: 1, operation: .ping, repository: nil, arguments: []))
    defer { Darwin.close(descriptor) }
    guard let frame = try readFrame(from: descriptor), frame.0 == .exit,
      String(data: frame.1, encoding: .utf8) == "0"
    else { throw AppError.broker("invalid ping response") }
  }

  private static func connect(_ request: BrokerRequest) throws -> Int32 {
    let descriptor = try UnixSocket.connect(path: Paths.socket.path)
    var data = try JSONEncoder().encode(request)
    data.append(0x0A)
    try UnixSocket.writeAll(descriptor, data)
    return descriptor
  }

  private static func discardRemoteCapabilities(_ descriptor: Int32) throws {
    var buffered = Data()
    while let frame = try readFrame(from: descriptor) {
      if frame.0 == .standardError {
        FileHandle.standardError.write(frame.1)
      } else if frame.0 == .standardOutput {
        buffered.append(frame.1)
        if buffered.range(of: Data("\n\n".utf8)) != nil { return }
      } else if frame.0 == .exit {
        throw AppError.broker("git transport exited during capability negotiation")
      }
    }
    throw AppError.broker("git transport closed during capability negotiation")
  }

  private static func relayOutput(_ descriptor: Int32) throws -> Int32 {
    while let frame = try readFrame(from: descriptor) {
      switch frame.0 {
      case .standardOutput: FileHandle.standardOutput.write(frame.1)
      case .standardError: FileHandle.standardError.write(frame.1)
      case .exit: return Int32(String(data: frame.1, encoding: .utf8) ?? "1") ?? 1
      default: throw AppError.broker("invalid output frame")
      }
    }
    throw AppError.broker("broker closed without an exit status")
  }
}

private func sendError(_ message: String, to descriptor: Int32) throws {
  try sendFrame(.standardError, Data("error: \(message)\n".utf8), to: descriptor)
  try sendFrame(.exit, Data("1".utf8), to: descriptor)
}
func sendFrame(_ channel: StreamChannel, _ payload: Data, to descriptor: Int32) throws {
  var length = UInt32(payload.count).bigEndian
  var data = Data([channel.rawValue])
  withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
  data.append(payload)
  try UnixSocket.writeAll(descriptor, data)
}
func readFrame(from descriptor: Int32) throws -> (StreamChannel, Data)? {
  guard let header = try UnixSocket.readExact(descriptor, count: 5) else { return nil }
  guard header.count == 5, let channel = StreamChannel(rawValue: header[0]) else {
    throw AppError.broker("invalid stream frame")
  }
  let length = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  guard length <= 16 * 1024 * 1024 else { throw AppError.broker("stream frame is too large") }
  guard let payload = try UnixSocket.readExact(descriptor, count: Int(length)) else {
    throw AppError.broker("truncated stream frame")
  }
  return (channel, payload)
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
    while result.count < limit {
      guard let data = try readExact(descriptor, count: 1) else { break }
      if data[0] == 0x0A { return result }
      result.append(data)
    }
    guard result.count < limit else { throw AppError.broker("message too large") }
    return result
  }
  static func readExact(_ descriptor: Int32, count: Int) throws -> Data? {
    if count == 0 { return Data() }
    var result = Data(count: count)
    var received = 0
    while received < count {
      let readCount = result.withUnsafeMutableBytes { raw in
        Darwin.read(descriptor, raw.baseAddress!.advanced(by: received), count - received)
      }
      if readCount == 0 { return received == 0 ? nil : Data(result.prefix(received)) }
      guard readCount > 0 else {
        if errno == EINTR { continue }
        throw AppError.system("read", errno)
      }
      received += readCount
    }
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
