import Foundation

let service = "net.eshlox.github-agent-auth"
let legacyService = "com.example.github-auth-broker"
let gitHubHost = "github.com"
let apiBase = URL(string: "https://api.github.com")!

enum AppError: LocalizedError {
  case config(String)
  case denied(String)
  case keychain(String)
  case github(String)
  case broker(String)
  case system(String, Int32)

  var errorDescription: String? {
    switch self {
    case .config(let message): "invalid configuration: \(message)"
    case .denied(let message): "request denied: \(message)"
    case .keychain(let message): "macOS Keychain error: \(message)"
    case .github(let message): "GitHub API error: \(message)"
    case .broker(let message): "broker error: \(message)"
    case .system(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
    }
  }
}

enum Paths {
  static var appDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("github-auth-broker", isDirectory: true)
  }
  static var config: URL { appDirectory.appendingPathComponent("config.json") }
  static var socket: URL { appDirectory.appendingPathComponent("broker.sock") }
  static var wrapper: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/gh")
  }
  static var launchAgent: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(service).plist")
  }
  static var legacyLaunchAgent: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(legacyService).plist")
  }
}

func setMode(_ path: String, _ mode: mode_t) throws {
  guard chmod(path, mode) == 0 else { throw AppError.system("chmod", errno) }
}

func runProcess(_ executable: String, _ arguments: [String], environment: [String: String]? = nil)
  throws -> (Int32, Data, Data)
{
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  if let environment { process.environment = environment }
  let output = Pipe()
  let error = Pipe()
  process.standardOutput = output
  process.standardError = error
  try process.run()
  process.waitUntilExit()
  return (
    process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile(),
    error.fileHandleForReading.readDataToEndOfFile()
  )
}

func commandPath(_ name: String, excluding excluded: URL? = nil) -> URL? {
  let fm = FileManager.default
  return ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":")
    .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
    .first {
      fm.isExecutableFile(atPath: $0.path)
        && $0.standardizedFileURL != excluded?.standardizedFileURL
    }
}

func openURL(_ url: URL) throws {
  guard try runProcess("/usr/bin/open", [url.absoluteString]).0 == 0 else {
    throw AppError.config("could not open the browser")
  }
}

func blockingAsync<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value)
  throws -> Value
{
  let box = AsyncResultBox<Value>()
  let semaphore = DispatchSemaphore(value: 0)
  Task {
    do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
    semaphore.signal()
  }
  semaphore.wait()
  return try box.result!.get()
}

private final class AsyncResultBox<Value: Sendable>: @unchecked Sendable {
  var result: Result<Value, Error>?
}

extension Data {
  var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
