enum PermissionProfile: String, CaseIterable {
  case core
  case developer

  var permissions: [String: String] {
    var values = [
      "contents": "write", "issues": "write", "metadata": "read",
      "pull_requests": "write",
    ]
    guard self == .developer else { return values }
    values.merge([
      "actions": "read", "checks": "read", "code_quality": "read",
      "deployments": "read", "discussions": "read", "merge_queues": "read",
      "security_events": "read", "statuses": "read", "vulnerability_alerts": "read",
    ]) { _, new in new }
    return values
  }

  var summary: String {
    self == .core
      ? "Contents, issues, and pull requests RW; metadata R"
      : "Core plus CI, code quality, code scanning, Dependabot, deployments, discussions, and merge queues R"
  }

  static func setupValue(_ value: String?) throws -> Self {
    let name = value ?? Self.core.rawValue
    guard let profile = Self(rawValue: name) else {
      throw AppError.config("--permissions must be core or developer")
    }
    return profile
  }
}
