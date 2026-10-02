import Darwin
import Foundation
import Testing

@testable import FreeSpace

struct WorkspaceControlTests {
  @Test @MainActor
  func savedStartCommandRunsOnlyOnRequestInItsProjectFolder() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "buildkeep-start-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let marker = folder.appendingPathComponent("started")
    let command =
      "/usr/bin/touch '" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let preference = WorkspacePreference(
      directory: folder.path, name: "Launch fixture", keepRunning: false, startCommand: command)
    let controller = WorkspaceController()
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    controller.start(.init(preference: preference, existingServers: []))
    let deadline = Date.now.addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: marker.path) && Date.now < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
  }
  @Test
  func incidentByteBudgetKeepsRecentEventsReadable() throws {
    var history = MemoryIncidentHistory()
    let latestID = UUID()
    for index in 0..<20 {
      history.append(
        MemoryIncident(
          id: index == 19 ? latestID : UUID(), date: .now,
          kind: "pressure", detail: String(repeating: "observed footprint ", count: 15),
          sample: nil, apps: []))
    }
    let data = try history.boundedData(maximumBytes: 2048)
    #expect(data.count <= 2048)
    let decoded = try JSONDecoder().decode(MemoryIncidentHistory.self, from: data)
    #expect(decoded.events.last?.id == latestID)
    #expect(decoded.events.count < 20)
  }
  @Test
  func separatesWorkersFromTheirHostWithoutLeakingArguments() throws {
    let records = RawProcessParser.records(
      "10 1 501 0 100 01:00 ?? ChatGPT\n"
        + "11 10 501 0 100 01:00 ?? codex app-server\n"
        + "12 11 501 0 100 01:00 ?? node tool-mcp.js --token super-secret-value\n"
        + "13 11 501 0 100 01:00 ?? java maestro.cli.AppKt mcp\n"
        + "14 11 501 0 100 01:00 ?? zsh -c echo mcp\n")
    let resources = ResourceOwnership.processes(
      .init(
        records: records, directories: [11: "/dev/product"],
        footprints: [10: 100, 11: 200, 12: 300],
        executables: [
          10: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", 11: "/bin/codex", 12: "/bin/node",
          13: "/bin/java", 14: "/bin/zsh",
        ]))
    #expect(resources.count == 5)
    #expect(resources.first { $0.id == 12 }?.owner == "ChatGPT")
    #expect(resources.first { $0.id == 12 }?.directory == "/dev/product")
    #expect(resources.first { $0.id == 13 }?.memoryBytes == nil)
    #expect(resources.first { $0.id == 14 }?.isTool == false)
    let data = try JSONEncoder().encode(ResourceOwnership.groups(resources))
    #expect(!String(decoding: data, as: UTF8.self).contains("super-secret-value"))
  }

  @Test
  func distinctCheckoutsWithSameNameHaveDistinctGroupIdentity() {
    let resources = ["/dev/one/app", "/dev/two/app"].enumerated().map { index, directory in
      ResourceProcess(
        processID: Int32(index + 10), parentProcessID: 1, name: "Node tools",
        owner: "Codex", directory: directory, memoryBytes: 100, cpuPercent: 0, isTool: true)
    }
    let groups = ResourceOwnership.groups(resources)
    #expect(groups.count == 2)
    #expect(Set(groups.map(\.id)).count == 2)
    #expect(groups.reduce(0) { $0 + $1.memoryBytes } == 200)
  }

  @Test
  func ownershipTraversalHandlesCyclesAndDoesNotCrossUsers() {
    let records = RawProcessParser.records(
      "10 11 501 0 100 01:00 ?? node mcp\n11 10 501 0 100 01:00 ?? node mcp\n12 10 502 0 100 01:00 ?? node mcp"
    )
    let result = ResourceOwnership.processes(
      .init(
        records: records, directories: [10: "/dev/private"], footprints: [:],
        executables: [10: "/bin/node", 11: "/bin/node", 12: "/bin/node"]))
    #expect(result.count == 3)
    #expect(result.first { $0.id == 12 }?.directory == nil)
  }

  @Test
  func legacyIncidentsDecodeWithoutInventingWorkerData() throws {
    let event = MemoryIncident(
      id: UUID(), date: .now, kind: "pressure", detail: "Critical", sample: nil, apps: [])
    let data = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(MemoryIncident.self, from: data)
    #expect(decoded.resources == nil)
  }

  @Test
  func keptProjectMembershipDoesNotMatchSimilarlyNamedNeighbors() {
    #expect(
      WorkspacePreferences.contains(.init(directory: "/tmp/product/apps/web", root: "/tmp/product"))
    )
    #expect(
      !WorkspacePreferences.contains(.init(directory: "/tmp/product-other", root: "/tmp/product")))
  }

  @Test @MainActor
  func requiresSavedCommandAndAvailableFolderBeforeStarting() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var preference = WorkspacePreference(
      directory: folder.path, name: "Fixture", keepRunning: true, startCommand: nil)
    #expect(
      WorkspaceController.startValidation(.init(preference: preference, existingServers: [])) != nil
    )
    preference.startCommand = "/bin/sleep 1"
    #expect(
      WorkspaceController.startValidation(.init(preference: preference, existingServers: [])) == nil
    )
    let server = DevProcess(
      processID: 100, parentProcessID: 1, kind: .devServer, name: "vite", detail: "dev",
      workingDirectory: folder.path, listeningPorts: [5173], cpuPercent: 0, memoryBytes: 100,
      elapsed: "00:01", terminal: nil)
    #expect(
      WorkspaceController.startValidation(.init(preference: preference, existingServers: [server]))
        != nil)
  }

  @Test
  func projectCatalogKeepsSavedStoppedProjects() {
    let preference = WorkspacePreference(
      directory: "/dev/saved-project", name: "Saved project", keepRunning: true,
      startCommand: "pnpm dev")
    let projects = WorkspaceCatalog.projects(
      .init(resources: [], processes: [], preferences: [preference]))
    #expect(projects.count == 1)
    #expect(projects.first?.preference == preference)
    #expect(projects.first?.servers.isEmpty == true)
  }

  @Test
  func projectCatalogListsRunningProjectsFirst() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("{}".utf8).write(to: folder.appendingPathComponent("package.json"))
    let running = WorkspacePreferences.canonical(folder.path)
    let kept = WorkspacePreference(
      directory: "/dev/kept-project", name: "Kept", keepRunning: true, startCommand: "pnpm dev")
    let server = DevProcess(
      processID: 100, parentProcessID: 1, kind: .devServer, name: "vite", detail: "dev",
      workingDirectory: running, listeningPorts: [5173], cpuPercent: 0, memoryBytes: 100,
      elapsed: "00:01", terminal: nil)
    let projects = WorkspaceCatalog.projects(
      .init(resources: [], processes: [server], preferences: [kept]))
    #expect(projects.map(\.isRunning) == [true, false])
    #expect(projects.last?.preference == kept)
  }
}
