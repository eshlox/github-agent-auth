import Darwin
import Foundation

struct HTTPRequest {
  let path: String
  let query: [String: String]
}

final class LoopbackHTTPServer: @unchecked Sendable {
  private let descriptor: Int32
  let port: UInt16

  init() throws {
    let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else { throw AppError.system("socket", errno) }
    var reuse: Int32 = 1
    setsockopt(
      socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
      socklen_t(MemoryLayout.size(ofValue: reuse)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, Darwin.listen(socketDescriptor, 8) == 0 else {
      let code = errno
      Darwin.close(socketDescriptor)
      throw AppError.system("bind loopback server", code)
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(socketDescriptor, $0, &length)
      }
    }
    guard result == 0 else {
      let code = errno
      Darwin.close(socketDescriptor)
      throw AppError.system("getsockname", code)
    }
    descriptor = socketDescriptor
    port = UInt16(bigEndian: actual.sin_port)
  }

  deinit { Darwin.close(descriptor) }

  var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

  func waitForRequest(
    timeout: TimeInterval, matching: (HTTPRequest) -> Bool,
    handler: (HTTPRequest) throws -> String?
  ) throws -> HTTPRequest {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let milliseconds = Int32(max(1, min(1_000, deadline.timeIntervalSinceNow * 1_000)))
      let ready = poll(&pollDescriptor, 1, milliseconds)
      if ready == 0 { continue }
      guard ready > 0 else {
        if errno == EINTR { continue }
        throw AppError.system("poll", errno)
      }
      let client = Darwin.accept(descriptor, nil, nil)
      guard client >= 0 else {
        if errno == EINTR { continue }
        throw AppError.system("accept", errno)
      }
      defer { Darwin.close(client) }
      do {
        let request = try readRequest(client)
        if let body = try handler(request) {
          try respond(client, status: "200 OK", body: body)
        } else {
          try respond(client, status: "404 Not Found", body: "Not found")
        }
        if matching(request) { return request }
      } catch {
        try? respond(client, status: "400 Bad Request", body: "Invalid request")
      }
    }
    throw AppError.config("timed out waiting for GitHub in the browser")
  }

  private func readRequest(_ client: Int32) throws -> HTTPRequest {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while data.count < 16 * 1_024, !data.contains(Data("\r\n\r\n".utf8)) {
      let count = Darwin.read(client, &buffer, buffer.count)
      guard count > 0 else { throw AppError.config("incomplete HTTP request") }
      data.append(buffer, count: count)
    }
    guard data.count < 16 * 1_024, let text = String(data: data, encoding: .utf8),
      let firstLine = text.components(separatedBy: "\r\n").first
    else {
      throw AppError.config("invalid HTTP request")
    }
    let parts = firstLine.split(separator: " ")
    guard parts.count == 3, parts[0] == "GET",
      let components = URLComponents(string: String(parts[1]))
    else {
      throw AppError.config("unsupported HTTP request")
    }
    var query: [String: String] = [:]
    for item in components.queryItems ?? [] where query[item.name] == nil {
      query[item.name] = item.value
    }
    return HTTPRequest(path: components.path, query: query)
  }

  private func respond(_ client: Int32, status: String, body: String) throws {
    let bodyData = Data(body.utf8)
    let header = Data(
      "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        .utf8)
    try UnixSocket.writeAll(client, header + bodyData)
  }
}
