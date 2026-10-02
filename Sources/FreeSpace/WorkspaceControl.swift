import AppKit
import Foundation

struct WorkspacePreference: Codable, Equatable, Identifiable, Sendable {
  let directory: String
  var name: String
  var keepRunning: Bool
  var startCommand: String?
  var id: String { directory }
}

enum WorkspacePreferences {
  static let key = "workspace.preferences.v1"

  static func load() -> [WorkspacePreference] {
    guard let data = UserDefaults.standard.data(forKey: key),
      let result = try? JSONDecoder().decode([WorkspacePreference].self, from: data)
    else { return [] }
    return result
  }

  static func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  struct Membership {
    let directory: String
    let root: String
  }

  static func contains(_ input: Membership) -> Bool {
    let directory = canonical(input.directory)
    let root = canonical(input.root)
    return directory == root || directory.hasPrefix(root + "/")
  }

  static func isKeptRunning(_ directory: String?) -> Bool {
    guard let directory else { return false }
    return load().contains {
      $0.keepRunning && contains(.init(directory: directory, root: $0.directory))
    }
  }
}

struct WorkspaceProject: Identifiable, Sendable {
  let directory: String
  let preference: WorkspacePreference
  let resources: [ResourceProcess]
  let servers: [DevProcess]
  var id: String { directory }
  var isRunning: Bool { !resources.isEmpty || !servers.isEmpty }
  var memoryBytes: UInt64 { resources.compactMap(\.memoryBytes).reduce(0, +) }
  var cpuPercent: Double { resources.reduce(0) { $0 + $1.cpuPercent } }
}

enum WorkspaceCatalog {
  struct Input {
    let resources: [ResourceProcess]
    let processes: [DevProcess]
    let preferences: [WorkspacePreference]
  }

  static func projects(_ input: Input) -> [WorkspaceProject] {
    resolvedProjects(.init(input: input, roots: resolveRoots(input)))
  }

  struct ResolvedInput {
    let input: Input
    let roots: [Int32: String]
  }

  static func resolveRoots(_ input: Input) -> [Int32: String] {
    let directories = Set(
      input.resources.compactMap(\.directory) + input.processes.compactMap(\.workingDirectory))
    let directoryRoots = Dictionary(
      uniqueKeysWithValues: directories.compactMap { directory in
        root(directory).map { (directory, $0) }
      })
    var parents = Dictionary(
      input.resources.map { ($0.id, $0.parentProcessID) }, uniquingKeysWith: { first, _ in first })
    var direct = Dictionary(
      uniqueKeysWithValues: input.resources.compactMap { resource in
        resource.directory.flatMap { directoryRoots[$0] }.map { (resource.id, $0) }
      })
    for process in input.processes {
      parents[process.id] = process.parentProcessID
      if let directory = process.workingDirectory, let root = directoryRoots[directory] {
        direct[process.id] = root
      }
    }
    var result: [Int32: String] = [:]
    for id in parents.keys {
      var current = id
      var visited: Set<Int32> = []
      while visited.insert(current).inserted {
        if let root = direct[current] ?? result[current] {
          for child in visited { result[child] = root }
          break
        }
        guard let parent = parents[current], parent > 1 else { break }
        current = parent
      }
    }
    return result
  }

  static func resolvedProjects(_ resolved: ResolvedInput) -> [WorkspaceProject] {
    let input = resolved.input
    let roots = resolved.roots
    let resourceGroups = Dictionary(grouping: input.resources) {
      roots[$0.id] ?? ""
    }
    let serverGroups = Dictionary(grouping: input.processes.filter(\.canStopWithProject)) {
      roots[$0.id] ?? ""
    }
    let allRoots = Set(roots.values).union(input.preferences.map(\.directory))
    return allRoots.map { directory in
      let preference =
        input.preferences.first { $0.directory == directory }
        ?? WorkspacePreference(
          directory: directory, name: URL(fileURLWithPath: directory).lastPathComponent,
          keepRunning: false, startCommand: nil)
      return WorkspaceProject(
        directory: directory, preference: preference,
        resources: resourceGroups[directory, default: []],
        servers: serverGroups[directory, default: []])
    }.sorted {
      if $0.isRunning != $1.isRunning { return $0.isRunning }
      if $0.preference.keepRunning != $1.preference.keepRunning { return $0.preference.keepRunning }
      if $0.memoryBytes != $1.memoryBytes { return $0.memoryBytes > $1.memoryBytes }
      return $0.preference.name < $1.preference.name
    }
  }

  static func root(_ directory: String) -> String? {
    guard
      !["/.npm/", "/.cache/", "/.local/", "/.codex/vendor/"].contains(
        where: directory.contains)
    else { return nil }
    let projectPath = directory.components(separatedBy: "/node_modules/").first ?? directory
    var url = URL(fileURLWithPath: WorkspacePreferences.canonical(projectPath))
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var manifest: String?
    for _ in 0..<12 {
      guard url.path != "/", url.path != home, !url.path.contains(".app/") else { break }
      if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
        return url.path
      }
      if manifest == nil
        && ["package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "go.mod"].contains(
          where: {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
          })
      {
        manifest = url.path
      }
      url.deleteLastPathComponent()
    }
    return manifest
  }
}

@MainActor
final class WorkspaceController: ObservableObject {
  @Published private(set) var preferences = WorkspacePreferences.load()
  @Published private(set) var starting: Set<String> = []
  @Published private(set) var status: String?
  private var launched: [String: Process] = [:]

  func save(_ preference: WorkspacePreference) {
    let directory = WorkspacePreferences.canonical(preference.directory)
    let value = WorkspacePreference(
      directory: directory, name: preference.name, keepRunning: preference.keepRunning,
      startCommand: preference.startCommand?.trimmingCharacters(in: .whitespacesAndNewlines))
    preferences.removeAll { $0.directory == directory }
    preferences.append(value)
    if let data = try? JSONEncoder().encode(preferences) {
      UserDefaults.standard.set(data, forKey: WorkspacePreferences.key)
    }
  }

  struct KeepRequest {
    let preference: WorkspacePreference
    let keep: Bool
  }

  func keep(_ request: KeepRequest) {
    var preference = request.preference
    preference.keepRunning = request.keep
    save(preference)
  }

  struct StartRequest: Sendable {
    let preference: WorkspacePreference
    let existingServers: [DevProcess]
  }

  static func startValidation(_ request: StartRequest) -> String? {
    guard request.existingServers.isEmpty else {
      return "This project already has a running server."
    }
    guard let command = request.preference.startCommand,
      !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return "Save a start command for this project first."
    }
    var directory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: request.preference.directory, isDirectory: &directory),
      directory.boolValue
    else {
      return "The project folder is no longer available."
    }
    return nil
  }

  func start(_ request: StartRequest) {
    if let error = Self.startValidation(request) {
      status = error
      return
    }
    let directory = request.preference.directory
    guard launched[directory]?.isRunning != true, !starting.contains(directory),
      let command = request.preference.startCommand
    else {
      status = "This project's saved command is already running."
      return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lic", command]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [weak self] finished in
      let code = finished.terminationStatus
      Task { @MainActor [weak self] in
        self?.launched.removeValue(forKey: directory)
        self?.starting.remove(directory)
        self?.status = "\(request.preference.name) start command exited (\(code))."
      }
    }
    do {
      starting.insert(directory)
      try process.run()
      launched[directory] = process
      status = "Started \(request.preference.name). Waiting for its server to appear."
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(12))
        self?.starting.remove(directory)
      }
    } catch {
      starting.remove(directory)
      status = "Could not start \(request.preference.name): \(error.localizedDescription)"
    }
  }
}
