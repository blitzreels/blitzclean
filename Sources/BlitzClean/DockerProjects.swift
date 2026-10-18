import Foundation

struct DockerProjectContainer: Decodable, Equatable, Sendable, Identifiable {
  let id: String
  let name: String
  let created: String
  let running: Bool
  let paused: Bool
  let labels: [String: String]?
  var assignedDirectory: String? = nil

  var directory: String? {
    let value =
      assignedDirectory ?? labels?["com.docker.compose.project.working_dir"]
      ?? labels?["com.supabase.cli.workdir"]
    guard let value, value.hasPrefix("/"), value != "/" else { return nil }
    return URL(fileURLWithPath: value).standardizedFileURL.path
  }

  var projectName: String {
    labels?["com.docker.compose.project"] ?? String(name.drop(while: { $0 == "/" }))
  }
}

struct DockerProjectSnapshot: Sendable {
  let endpoint: String
  let containers: [DockerProjectContainer]
}

struct DockerProjectService: Sendable {
  let docker: DockerStorageService
  private static let format =
    "{\"id\":{{json .Id}},\"name\":{{json .Name}},\"created\":{{json .Created}},\"running\":{{.State.Running}},\"paused\":{{.State.Paused}},\"labels\":{{json .Config.Labels}}}"

  func load() throws -> DockerProjectSnapshot {
    let endpoint = try docker.localEndpoint()
    let ids = try docker.run(
      .init(arguments: ["--host", endpoint, "ps", "--all", "--quiet", "--no-trunc"], timeout: 3)
    )
    .standardOutput.split(whereSeparator: \.isWhitespace).map(String.init)
    guard ids.count <= 256, ids.allSatisfy(Self.validID) else {
      throw DockerStorageError.invalidOutput
    }
    let assignments =
      UserDefaults.standard.dictionary(forKey: "docker.projectDirectories") as? [String: String]
      ?? [:]
    let containers = try inspect(.init(endpoint: endpoint, ids: ids)).map { original in
      var container = original
      container.assignedDirectory = assignments[container.id]
      return container
    }
    return .init(endpoint: endpoint, containers: containers)
  }

  struct Inspection {
    let endpoint: String
    let ids: [String]
  }

  func inspect(_ input: Inspection) throws -> [DockerProjectContainer] {
    guard !input.ids.isEmpty else { return [] }
    let output = try docker.run(
      .init(
        arguments: [
          "--host", try DockerLocalEndpoint.validate(input.endpoint),
          "inspect", "--format", Self.format,
        ] + input.ids, timeout: 3))
    return try Self.parse(output.standardOutput)
  }

  static func parse(_ output: String) throws -> [DockerProjectContainer] {
    try output.split(separator: "\n").map { line in
      let value = try JSONDecoder().decode(DockerProjectContainer.self, from: Data(line.utf8))
      guard validID(value.id) else { throw DockerStorageError.invalidOutput }
      return value
    }
  }

  static func validID(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit && $0.isASCII }
  }

  struct Action: Sendable {
    let endpoint: String
    let containers: [DockerProjectContainer]
    let start: Bool
  }

  func apply(_ action: Action) throws -> String {
    let endpoint = try DockerLocalEndpoint.validate(action.endpoint)
    var changed = 0
    for expected in action.containers {
      guard Self.validID(expected.id),
        let current = try inspect(.init(endpoint: endpoint, ids: [expected.id])).first,
        current.id == expected.id, current.created == expected.created,
        current.labels == expected.labels
      else {
        throw DockerStorageError.commandFailed("A container changed. Refresh before trying again.")
      }
      if !action.start, let directory = expected.directory,
        WorkspacePreferences.isKeptRunning(directory)
      {
        throw DockerStorageError.commandFailed("This project is set to Keep running.")
      }
      if action.start && current.running && !current.paused { continue }
      if !action.start && !current.running { continue }
      if current.paused {
        _ = try docker.run(
          .init(arguments: ["--host", endpoint, "unpause", current.id], timeout: 3))
      }
      _ = try docker.run(
        .init(
          arguments: ["--host", endpoint]
            + (action.start
              ? ["start", current.id] : ["stop", "--timeout", "-1", current.id]),
          timeout: 12))
      let verified = try inspect(.init(endpoint: endpoint, ids: [current.id])).first
      guard verified?.running == action.start, verified?.paused == false else {
        throw DockerStorageError.commandFailed("Container state did not reach the requested state.")
      }
      changed += 1
    }
    return
      "\(action.start ? "Started" : "Stopped") \(changed) containers. Database volumes preserved."
  }
}

@MainActor
final class DockerProjectsModel: ObservableObject {
  @Published private(set) var snapshot: DockerProjectSnapshot?
  @Published private(set) var message: String?
  @Published private(set) var refreshing = false
  @Published private(set) var acting: Set<String> = []
  private var checkedAt = Date.distantPast
  private let service = DockerProjectService(docker: DockerStorageService())

  struct Assignment {
    let containers: [DockerProjectContainer]
    let directory: String
  }

  func assign(_ input: Assignment) {
    var values =
      UserDefaults.standard.dictionary(forKey: "docker.projectDirectories") as? [String: String]
      ?? [:]
    for container in input.containers {
      values[container.id] = WorkspacePreferences.canonical(input.directory)
    }
    UserDefaults.standard.set(values, forKey: "docker.projectDirectories")
    checkedAt = .distantPast
    refresh()
  }

  func refresh() {
    guard !refreshing, acting.isEmpty, Date.now.timeIntervalSince(checkedAt) > 15 else { return }
    refreshing = true
    let service = service
    Task {
      let result = await Task.detached(priority: .utility) { Result { try service.load() } }.value
      refreshing = false
      checkedAt = .now
      switch result {
      case .success(let value):
        snapshot = value
        if message?.hasPrefix("Docker inspection unavailable:") == true { message = nil }
      case .failure(let error):
        snapshot = nil
        message = "Docker inspection unavailable: \(error.localizedDescription)"
      }
    }
  }

  struct Request {
    let directory: String
    let containers: [DockerProjectContainer]
    let start: Bool
  }

  func apply(_ request: Request) async -> String {
    guard let snapshot, acting.insert(request.directory).inserted else {
      return "Docker action already running."
    }
    let service = service
    let action = DockerProjectService.Action(
      endpoint: snapshot.endpoint, containers: request.containers, start: request.start)
    let result = await Task.detached(priority: .userInitiated) {
      Result { try service.apply(action) }
    }.value
    acting.remove(request.directory)
    checkedAt = .distantPast
    let text: String
    switch result {
    case .success(let value): text = value
    case .failure(let error): text = "Docker action incomplete: \(error.localizedDescription)"
    }
    message = text
    refresh()
    return text
  }
}
