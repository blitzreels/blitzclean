import Foundation
import SQLite3
import Testing

@testable import FreeSpace

struct AIThreadNamesTests {
  @Test func exactSessionIDsOnly() {
    let id = UUID().uuidString.lowercased()
    #expect(
      AIThreadNames.sessionID(.init(tool: .codexCLI, arguments: ["codex", "resume", id])) == id)
    #expect(
      AIThreadNames.sessionID(
        .init(tool: .claudeCode, arguments: ["claude", "--session-id=\(id)"]))
        == id)
    #expect(
      AIThreadNames.sessionID(
        .init(tool: .cursorAgent, arguments: ["cursor-agent", "--resume", id]))
        == id)
    #expect(
      AIThreadNames.sessionID(
        .init(tool: .codexCLI, arguments: ["codex", "exec", "discuss \(id)"])) == nil)
    #expect(
      AIThreadNames.sessionID(
        .init(tool: .claudeCode, arguments: ["claude", "--resume", "latest"])) == nil)
  }

  @Test func nativeArgumentsKeepPromptsSeparateAndExcludeEnvironment() {
    var count: Int32 = 3
    var data = Data(bytes: &count, count: MemoryLayout<Int32>.size)
    data.append(
      Data(
        "/bin/codex\0\0codex\0exec\0resume 01234567-0123-0123-0123-012345678901\0SECRET=hidden\0"
          .utf8))
    let arguments = AIThreadNames.arguments(data)
    #expect(arguments.count == 3)
    #expect(!arguments.joined().contains("SECRET"))
    #expect(AIThreadNames.sessionID(.init(tool: .codexCLI, arguments: arguments)) == nil)
    #expect(AIThreadNames.arguments(Data([0, 1])) == [])
  }

  @Test func codexIndexKeepsLatestNameAndToleratesIncompleteRows() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let rows = """
      partial row
      {"id":"test","thread_name":"Old name"}
      {"id":"test","thread_name":"Fix app navigation"}
      {"id":"empty","thread_name":"   "}
      {"id":
      """
    try Data(rows.utf8).write(to: file)
    #expect(AIThreadNames.codexIndex(file) == ["test": "Fix app navigation"])
  }

  @Test func staleClaudePIDCannotNameNewProcess() {
    #expect(
      AIThreadNames.registryMatches(
        .init(
          metadata: ["procStart": "Sat Oct  3 13:26:57 2026"], startedAt: 1_791_034_017)))
    #expect(
      !AIThreadNames.registryMatches(.init(metadata: ["startedAt": 100_000.0], startedAt: 200)))
    #expect(
      AIThreadNames.registryMatches(.init(metadata: ["startedAt": 200_500.0], startedAt: 200)))
    #expect(!AIThreadNames.registryMatches(.init(metadata: [:], startedAt: 200)))
  }

  @Test func claudeSessionNameRequiresCurrentPIDIdentity() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let sessions = home.appendingPathComponent(".claude/sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let id = UUID().uuidString.lowercased()
    let metadata: [String: Any] = [
      "pid": 42, "sessionId": id, "startedAt": 200_000.0, "name": "Fix recording controls",
    ]
    try JSONSerialization.data(withJSONObject: metadata).write(
      to: sessions.appendingPathComponent("42.json"))
    let record = RawProcessRecord(
      processID: 42, parentProcessID: 1, userID: 501, cpuPercent: 0, residentKilobytes: 1,
      elapsed: "01:00", terminal: nil, arguments: "claude")
    let thread = AIThread(
      id: "claude", tool: .claudeCode, name: "Claude Code", directory: "/project", terminal: nil,
      startedAt: nil, processIDs: [42], memoryBytes: 1, cpuPercent: 0, isPaused: false,
      isDetached: false)
    let result = AIThreadNames.enrich(
      .init(threads: [thread], records: [record], startTimes: [42: 200], home: home))
    #expect(result.first?.sessionTitle == "Fix recording controls")
    #expect(result.first?.sessionID == id)
    let reused = AIThreadNames.enrich(
      .init(threads: [thread], records: [record], startTimes: [42: 400], home: home))
    #expect(reused.first?.sessionTitle == nil)
  }

  @Test func cursorReadsOnlyMatchingSessionMetadata() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let id = UUID().uuidString.lowercased()
    let folder = home.appendingPathComponent(".cursor/chats/workspace/\(id)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var database: OpaquePointer?
    #expect(sqlite3_open(folder.appendingPathComponent("store.db").path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    let json = try JSONSerialization.data(withJSONObject: [
      "agentId": id, "name": "Repair timeline", "blobEncryptionKey": "unused",
    ])
    let hex = json.map { String(format: "%02x", $0) }.joined()
    #expect(
      sqlite3_exec(
        database,
        "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT); INSERT INTO meta VALUES ('0', '\(hex)');",
        nil, nil, nil) == SQLITE_OK)
    #expect(AIThreadNames.cursorTitle(.init(home: home, sessionID: id)) == "Repair timeline")
    #expect(
      AIThreadNames.cursorTitle(.init(home: home, sessionID: UUID().uuidString.lowercased())) == nil
    )
  }

  @Test func namesAreBoundedAndSearchIncludesDelegation() {
    #expect(AIThreadNames.cleanTitle("hello\nworld") == "hello world")
    #expect(AIThreadNames.cleanTitle(String(repeating: "a", count: 200))?.count == 160)
    var thread = AIThread(
      id: "claude", tool: .claudeCode, name: "Claude Code", directory: "/dev/blitzreels",
      terminal: nil,
      startedAt: nil, processIDs: [42], memoryBytes: 1, cpuPercent: 0, isPaused: false,
      isDetached: false)
    thread.sessionTitle = "Fix export"
    thread.hostName = "cmux"
    thread.delegatedTools = ["Codex CLI"]
    #expect(thread.displayName == "Fix export")
    for query in ["export", "claude", "codex", "blitzreels", "cmux", "42"] {
      #expect(thread.matches(query))
    }
    #expect(!thread.matches("other project"))
  }
}
