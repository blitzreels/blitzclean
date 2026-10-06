import Foundation

struct DockerStorageCategory: Identifiable, Codable, Equatable, Sendable {
  let id: String
  let name: String
  let totalCount: Int
  let activeCount: Int
  let sizeBytes: UInt64
  let reclaimableBytes: UInt64

  var isProtected: Bool {
    id == "containers" || id == "volumes"
  }
}

struct DockerStorageSnapshot: Codable, Equatable, Sendable {
  let categories: [DockerStorageCategory]
  let updatedAt: Date

  var totalBytes: UInt64 {
    categories.reduce(0) { result, category in
      result + category.sizeBytes
    }
  }

  var rebuildableBytes: UInt64 {
    categories.filter { category in
      category.id == "images" || category.id == "build-cache"
    }.reduce(0) { result, category in
      result + category.reclaimableBytes
    }
  }
}

enum DockerStorageOutcome: Sendable {
  case success(DockerStorageSnapshot)
  case failure(String)
}

enum DockerCleanupOutcome: Sendable {
  case success(String)
  case failure(String)
}

struct DockerStorageService: Sendable {
  let executablePath: String?

  init() {
    executablePath = [
      "/usr/local/bin/docker",
      "/opt/homebrew/bin/docker",
    ].first { path in
      FileManager.default.isExecutableFile(atPath: path)
    }
  }

  var isInstalled: Bool {
    executablePath != nil
  }

  func load() throws -> DockerStorageSnapshot {
    let host = try localEndpoint()
    let output = try run(
      DockerCommandRequest(arguments: ["--host", host, "system", "df", "--format", "{{json .}}"])
    )
    let categories = try DockerStorageParser.categories(output.standardOutput)

    return DockerStorageSnapshot(categories: categories, updatedAt: .now)
  }

  func cleanRebuildable() throws -> String {
    let host = try localEndpoint()
    let imageOutput = try run(
      DockerCommandRequest(arguments: ["--host", host, "image", "prune", "--force"])
    )
    let buildOutput = try run(
      DockerCommandRequest(arguments: ["--host", host, "builder", "prune", "--all", "--force"])
    )

    return [imageOutput.standardOutput, buildOutput.standardOutput]
      .filter { output in !output.isEmpty }
      .joined(separator: "\n")
  }

  private func localEndpoint() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    // Resolve the same target the CLI would use, then pin both cleanup commands to it.
    if environment["DOCKER_CONTEXT", default: ""].isEmpty,
      let host = environment["DOCKER_HOST"], !host.isEmpty
    {
      return try DockerLocalEndpoint.validate(host)
    }
    let output = try run(.init(arguments: ["context", "inspect"]))
    return try DockerLocalEndpoint.parse(output.standardOutput)
  }

  private func run(_ request: DockerCommandRequest) throws -> DockerCommandOutput {
    guard let executablePath else {
      throw DockerStorageError.notInstalled
    }

    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = request.arguments
    if request.arguments.first == "--host" {
      var environment = ProcessInfo.processInfo.environment
      for key in [
        "DOCKER_CONTEXT", "DOCKER_HOST", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH",
      ] {
        environment.removeValue(forKey: key)
      }
      process.environment = environment
    }
    process.standardOutput = standardOutput
    process.standardError = standardError

    try process.run()
    process.waitUntilExit()

    let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: outputData, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let error = String(decoding: errorData, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)

    guard process.terminationStatus == 0 else {
      throw DockerStorageError.commandFailed(error.isEmpty ? output : error)
    }

    return DockerCommandOutput(standardOutput: output)
  }
}

enum DockerLocalEndpoint {
  static func validate(_ host: String) throws -> String {
    guard host.hasPrefix("unix:///"), let url = URL(string: host),
      url.scheme == "unix", url.host == nil || url.host == "",
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      !url.path.isEmpty, url.path != "/"
    else {
      throw DockerStorageError.commandFailed(
        "Docker cleanup requires a local Unix socket. Remote contexts are not supported.")
    }
    return host
  }

  static func parse(_ output: String) throws -> String {
    struct Context: Decodable {
      struct Endpoint: Decodable {
        let host: String
        enum CodingKeys: String, CodingKey { case host = "Host" }
      }
      let endpoints: [String: Endpoint]
      enum CodingKeys: String, CodingKey { case endpoints = "Endpoints" }
    }
    guard let contexts = try? JSONDecoder().decode([Context].self, from: Data(output.utf8)),
      contexts.count == 1, let host = contexts.first?.endpoints["docker"]?.host
    else { throw DockerStorageError.invalidOutput }
    return try validate(host)
  }
}

struct DockerCommandRequest: Sendable {
  let arguments: [String]
}

struct DockerCommandOutput: Sendable {
  let standardOutput: String
}

enum DockerStorageError: LocalizedError {
  case notInstalled
  case commandFailed(String)
  case invalidOutput

  var errorDescription: String? {
    switch self {
    case .notInstalled:
      return "Docker CLI is not installed."
    case .commandFailed(let message):
      return message.isEmpty ? "Docker Desktop is not available." : message
    case .invalidOutput:
      return "Docker returned an unreadable storage report."
    }
  }
}

enum DockerStorageParser {
  static func categories(_ output: String) throws -> [DockerStorageCategory] {
    let rows = output.split(whereSeparator: \Character.isNewline)
    let categories = try rows.map { row in
      let data = Data(row.utf8)
      guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let type = values["Type"] as? String
      else {
        throw DockerStorageError.invalidOutput
      }

      return DockerStorageCategory(
        id: identifier(type),
        name: displayName(type),
        totalCount: integer(values["TotalCount"]),
        activeCount: integer(values["Active"]),
        sizeBytes: DockerByteParser.bytes(string(values["Size"])),
        reclaimableBytes: DockerByteParser.bytes(string(values["Reclaimable"]))
      )
    }

    guard !categories.isEmpty else {
      throw DockerStorageError.invalidOutput
    }

    let order = ["images", "build-cache", "containers", "volumes"]
    return categories.sorted { left, right in
      (order.firstIndex(of: left.id) ?? order.count)
        < (order.firstIndex(of: right.id) ?? order.count)
    }
  }

  private static func identifier(_ type: String) -> String {
    switch type {
    case "Images":
      return "images"
    case "Containers":
      return "containers"
    case "Local Volumes":
      return "volumes"
    case "Build Cache":
      return "build-cache"
    default:
      return type.lowercased().replacingOccurrences(of: " ", with: "-")
    }
  }

  private static func displayName(_ type: String) -> String {
    type == "Local Volumes" ? "Volumes" : type
  }

  private static func integer(_ value: Any?) -> Int {
    if let value = value as? Int {
      return value
    }

    return Int(string(value)) ?? 0
  }

  private static func string(_ value: Any?) -> String {
    if let value = value as? String {
      return value
    }

    return value.map(String.init(describing:)) ?? ""
  }
}

enum DockerByteParser {
  static func bytes(_ value: String) -> UInt64 {
    let amount = value.split(separator: " ").first.map(String.init) ?? value
    let numberText = amount.prefix { character in
      character.isNumber || character == "." || character == ","
    }.replacingOccurrences(of: ",", with: ".")
    let unit = amount.dropFirst(numberText.count).lowercased()
    guard let number = Double(numberText) else {
      return 0
    }

    let multiplier: Double
    switch unit {
    case "kb":
      multiplier = 1_000
    case "mb":
      multiplier = 1_000_000
    case "gb":
      multiplier = 1_000_000_000
    case "tb":
      multiplier = 1_000_000_000_000
    default:
      multiplier = 1
    }

    return UInt64(max(0, number * multiplier))
  }
}

@MainActor
final class DockerStorageModel: ObservableObject {
  @Published private(set) var snapshot: DockerStorageSnapshot?
  @Published private(set) var isRefreshing = false
  @Published private(set) var isCleaning = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var cleanupMessage: String?

  private let service = DockerStorageService()
  private var didStartRefresh = false

  init() {
    snapshot = DockerStorageCache.load()
  }

  var isInstalled: Bool {
    service.isInstalled
  }

  func refreshIfNeeded() {
    guard !didStartRefresh else {
      return
    }

    refresh()
  }

  func refresh() {
    guard !isRefreshing, !isCleaning else {
      return
    }

    didStartRefresh = true
    isRefreshing = true
    errorMessage = nil
    let service = service

    Task { [weak self] in
      let outcome = await Task.detached(priority: .utility) {
        do {
          return DockerStorageOutcome.success(try service.load())
        } catch {
          return DockerStorageOutcome.failure(error.localizedDescription)
        }
      }.value

      guard let self else {
        return
      }

      isRefreshing = false
      switch outcome {
      case .success(let snapshot):
        self.snapshot = snapshot
        DockerStorageCache.save(snapshot)
      case .failure(let message):
        errorMessage = message
      }
    }
  }

  func cleanRebuildable() {
    guard !isCleaning, !isRefreshing else {
      return
    }

    isCleaning = true
    cleanupMessage = nil
    errorMessage = nil
    let service = service

    Task { [weak self] in
      let outcome = await Task.detached(priority: .utility) {
        do {
          return DockerCleanupOutcome.success(try service.cleanRebuildable())
        } catch {
          return DockerCleanupOutcome.failure(error.localizedDescription)
        }
      }.value

      guard let self else {
        return
      }

      isCleaning = false
      switch outcome {
      case .success:
        cleanupMessage =
          "Removed unused images and build cache. Containers and volumes were protected."
        refresh()
      case .failure(let message):
        errorMessage = message
      }
    }
  }
}

enum DockerStorageCache {
  private static let key = "docker-storage-snapshot-v1"

  static func load() -> DockerStorageSnapshot? {
    guard let data = UserDefaults.standard.data(forKey: key) else {
      return nil
    }

    return try? JSONDecoder().decode(DockerStorageSnapshot.self, from: data)
  }

  static func save(_ snapshot: DockerStorageSnapshot) {
    guard let data = try? JSONEncoder().encode(snapshot) else {
      return
    }

    UserDefaults.standard.set(data, forKey: key)
  }
}
