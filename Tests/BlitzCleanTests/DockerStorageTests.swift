import Foundation
import Testing

@testable import BlitzClean

struct DockerStorageTests {
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
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
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
