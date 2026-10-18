import Foundation
import Testing

@testable import BlitzClean

struct DockerProjectTests {
  @Test func dockerOnlyAndSupabaseProjectsAppearWithoutHostListeners() throws {
    let containers = try DockerProjectService.parse(
      """
      {"id":"\(String(repeating: "a", count: 64))","name":"/db","created":"1","running":true,"paused":false,"labels":{"com.supabase.cli.workdir":"/tmp/qa","com.docker.compose.project":"qa"}}
      {"id":"\(String(repeating: "b", count: 64))","name":"/unknown","created":"2","running":false,"paused":false,"labels":null}
      """)
    let projects = WorkspaceCatalog.includingDocker(.init(projects: [], containers: containers))
    #expect(projects.count == 2)
    #expect(projects.first?.directory == "/tmp/qa")
    #expect(projects.first?.isRunning == true)
    #expect(projects.last?.directory.hasPrefix("docker:") == true)
    #expect(projects.last?.isRunning == false)
    #expect(throws: (any Error).self) {
      try DockerProjectService.parse(
        """
        {"id":"--all","name":"bad","created":"1","running":true,"paused":false,"labels":null}
        """)
    }
  }

  @Test func hostAndDockerResourcesShareOneProject() {
    let root = "/tmp/project"
    let project = WorkspaceProject(
      directory: root,
      preference: .init(
        directory: root, name: "Project", keepRunning: true, startCommand: "npm run dev"),
      resources: [], servers: [])
    let container = DockerProjectContainer(
      id: String(repeating: "a", count: 64), name: "/db", created: "1",
      running: true, paused: false, labels: ["com.docker.compose.project.working_dir": root])
    let result = WorkspaceCatalog.includingDocker(
      .init(projects: [project], containers: [container]))
    #expect(result.count == 1)
    #expect(result.first?.preference.keepRunning == true)
    #expect(result.first?.containers.count == 1)
  }

  @Test func stopPreservesContainersAndVolumesAndVerifiesFinalState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("docker")
    let log = root.appendingPathComponent("commands")
    let marker = root.appendingPathComponent("stopped")
    let id = String(repeating: "a", count: 64)
    let body = """
      #!/bin/sh
      printf '%s\\n' "$*" >> '\(log.path)'
      case "$3" in
        inspect)
          running=true
          [ -f '\(marker.path)' ] && running=false
          printf '{"id":"\(id)","name":"/db","created":"1","running":%s,"paused":false,"labels":null}\\n' "$running"
          ;;
        stop) touch '\(marker.path)' ;;
        *) exit 9 ;;
      esac
      """
    try Data(body.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let service = DockerProjectService(
      docker: .init(.init(executablePath: script.path, queryTimeout: 1)))
    let expected = DockerProjectContainer(
      id: id, name: "/db", created: "1", running: true, paused: false, labels: nil)
    let result = try service.apply(
      .init(endpoint: "unix:///var/run/docker.sock", containers: [expected], start: false))
    #expect(result.contains("Stopped 1"))
    let commands = try String(contentsOf: log, encoding: .utf8)
    #expect(commands.contains("stop --timeout 120 \(id)"))
    #expect(!commands.contains("prune"))
    #expect(!commands.contains(" rm "))
    let changed = DockerProjectContainer(
      id: id, name: "/db", created: "different", running: true,
      paused: false, labels: nil)
    #expect(throws: (any Error).self) {
      try service.apply(
        .init(endpoint: "unix:///var/run/docker.sock", containers: [changed], start: false))
    }
  }
}
