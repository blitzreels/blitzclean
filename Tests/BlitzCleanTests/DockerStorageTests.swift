import Foundation
import Testing

@testable import BlitzClean

struct DockerStorageTests {
  @Test func rejectsRemoteAndMalformedDockerEndpoints() throws {
    #expect(
      try DockerLocalEndpoint.validate("unix:///var/run/docker.sock")
        == "unix:///var/run/docker.sock")
    for host in [
      "ssh://production", "tcp://127.0.0.1:2375", "https://docker.example.com",
      "unix://remote/socket", "unix:///", "unix:///socket?other=host",
    ] {
      #expect(throws: (any Error).self) { try DockerLocalEndpoint.validate(host) }
    }
    #expect(throws: (any Error).self) { try DockerLocalEndpoint.parse("[]") }
    #expect(throws: (any Error).self) { try DockerLocalEndpoint.parse("not JSON") }
    #expect(
      try DockerLocalEndpoint.parse(
        "[{\"Endpoints\":{\"docker\":{\"Host\":\"unix:///var/run/docker.sock\"}}}]")
        == "unix:///var/run/docker.sock")
    #expect(throws: (any Error).self) {
      try DockerLocalEndpoint.parse(
        "[{\"Endpoints\":{\"docker\":{\"Host\":\"ssh://production\"}}}]")
    }
  }

  @Test func cleanupPinsBothCommandsAndPreservesTaggedImages() throws {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent(
      "docker-commands-\(UUID())")
    defer { try? FileManager.default.removeItem(at: log) }
    let script = try executable(
      """
      for key in DOCKER_CONTEXT DOCKER_HOST DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
        eval "value=\\${$key-}"
        [ -z "$value" ] || exit 9
      done
      printf '%s\\n' "$*" >> '\(log.path)'
      """)
    defer { try? FileManager.default.removeItem(at: script) }
    _ = try DockerStorageService(.init(executablePath: script.path, queryTimeout: 3))
      .cleanRebuildable()
    #expect(
      try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init) == [
        "--host unix:///var/run/docker.sock image prune --force",
        "--host unix:///var/run/docker.sock builder prune --all --force",
      ])
  }

  @Test func stalledDockerQueryEndsWithoutBlockingTheAudit() throws {
    let script = try executable("exec /bin/sleep 30")
    defer { try? FileManager.default.removeItem(at: script) }
    let service = DockerStorageService(.init(executablePath: script.path, queryTimeout: 0.1))
    let start = Date.now
    #expect(throws: DockerStorageError.self) { try service.load() }
    #expect(Date.now.timeIntervalSince(start) < 3)
  }

  @Test func largeDockerReportsDrainBeforeWaitingForExit() throws {
    let script = try executable(
      """
      i=0
      while [ "$i" -lt 2048 ]; do
        printf '%s\\n' '{"Active":"0","Reclaimable":"1GB","Size":"1GB","TotalCount":"1","Type":"Images"}'
        i=$((i + 1))
      done
      """)
    defer { try? FileManager.default.removeItem(at: script) }
    let result = try DockerStorageService(
      .init(executablePath: script.path, queryTimeout: 3)
    ).load()
    #expect(result.categories.count == 2048)
  }

  @Test func dockerFailuresKeepTheirDiagnosticMessage() throws {
    let script = try executable("printf 'daemon unavailable' >&2\nexit 1")
    defer { try? FileManager.default.removeItem(at: script) }
    #expect(throws: DockerStorageError.commandFailed("daemon unavailable")) {
      try DockerStorageService(.init(executablePath: script.path, queryTimeout: 3)).load()
    }
  }

  @Test func dockerWarningsDoNotCorruptAValidReport() throws {
    let script = try executable(
      """
      printf 'WARNING: test warning\\n' >&2
      printf '%s\\n' '{"Active":"0","Reclaimable":"1GB","Size":"1GB","TotalCount":"1","Type":"Images"}'
      """)
    defer { try? FileManager.default.removeItem(at: script) }
    let result = try DockerStorageService(
      .init(executablePath: script.path, queryTimeout: 3)
    ).load()
    #expect(result.rebuildableBytes == 1_000_000_000)
  }

  private func executable(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("docker-test-\(UUID())")
    let context = """
      if [ "$1" = context ]; then
        printf '%s\\n' '[{"Endpoints":{"docker":{"Host":"unix:///var/run/docker.sock"}}}]'
        exit 0
      fi
      """
    try Data(("#!/bin/sh\n" + context + "\n" + body + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  @Test
  func parsesDockerSizes() {
    #expect(DockerByteParser.bytes("0B") == 0)
    #expect(DockerByteParser.bytes("614.6MB (100%)") == 614_600_000)
    #expect(DockerByteParser.bytes("1.546GB (85%)") == 1_546_000_000)
  }

  @Test
  func parsesAndOrdersDockerBreakdown() throws {
    let output = """
      {"Active":"0","Reclaimable":"614.6MB (100%)","Size":"614.6MB","TotalCount":"10","Type":"Local Volumes"}
      {"Active":"1","Reclaimable":"1.546GB (85%)","Size":"1.815GB","TotalCount":"4","Type":"Images"}
      {"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Build Cache"}
      {"Active":"1","Reclaimable":"0B (0%)","Size":"7.881MB","TotalCount":"1","Type":"Containers"}
      """

    let categories = try DockerStorageParser.categories(output)

    #expect(categories.map(\.id) == ["images", "build-cache", "containers", "volumes"])
    #expect(categories.first?.reclaimableBytes == 1_546_000_000)
    #expect(categories.last?.isProtected == true)
  }
}
