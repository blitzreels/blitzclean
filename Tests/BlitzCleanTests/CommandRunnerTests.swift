import Foundation
import Testing

@testable import BlitzClean

struct CommandRunnerTests {
  @Test
  func returnsOutputAndStatus() {
    let output = run(
      .init(executable: "/bin/sh", arguments: ["-c", "echo hi; echo oops >&2; exit 3"]))
    #expect(output.ending == .exited(3))
    #expect(output.status == 3)
    #expect(output.text == "hi\n")
    #expect(output.errors == "oops\n")
  }

  @Test
  func stopsCommandsAndTheirChildrenAtTheDeadline() {
    let started = Date.now
    let script = TestProcesses.guardLine + "\nsleep 30 & sleep 30; wait"
    let output = run(.init(executable: "/bin/sh", arguments: ["-c", script], timeout: 0.5))
    #expect(output.ending == .timedOut)
    #expect(output.status == -1)
    #expect(Date.now.timeIntervalSince(started) < 5)
  }

  @Test
  func stopsCommandsThatExceedTheOutputLimit() {
    let yes = TestProcesses.guarded(.init(executable: "/usr/bin/yes", arguments: []))
    let output = run(
      .init(executable: yes.executable, arguments: yes.arguments, maximumBytes: 100_000))
    #expect(output.ending == .outputLimit)
    #expect(output.data.count <= 100_000)
  }

  @Test
  func streamsLargeInputWithoutDeadlock() {
    let input = Data(repeating: UInt8(ascii: "a"), count: 4 * 1_024 * 1_024)
    let output = run(.init(executable: "/bin/cat", arguments: [], input: input))
    #expect(output.ending == .exited(0))
    #expect(output.data == input)
  }

  @Test
  func appliesEnvironmentChanges() {
    let output = run(
      .init(
        executable: "/bin/sh", arguments: ["-c", "echo \"$GIT_TERMINAL_PROMPT-${HOME:-none}\""],
        environment: .init(set: ["GIT_TERMINAL_PROMPT": "0"], removed: ["HOME"])))
    #expect(output.text == "0-none\n")
  }

  @Test
  func reportsMissingExecutables() {
    let output = run(.init(executable: "/nonexistent/tool", arguments: []))
    #expect(output.ending == .notStarted)
    #expect(output.status == -1)
  }

  @Test
  func measuresFoldersEvenWithUnreadableEntries() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("disk-usage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("locked"), withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("locked").path)
      try? FileManager.default.removeItem(at: root)
    }
    try Data(repeating: 1, count: 256 * 1_024).write(to: root.appendingPathComponent("data.bin"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent("locked").path)
    let bytes = try #require(DiskUsage.allocatedBytes(.init(path: root.path, timeout: 10)))
    #expect(bytes >= 256 * 1_024)
  }

  private struct Spec {
    let executable: String
    let arguments: [String]
    var timeout: TimeInterval = 10
    var maximumBytes = 16 * 1_024 * 1_024
    var input: Data? = nil
    var environment: CommandRunner.Environment = .inherited
  }

  private func run(_ spec: Spec) -> CommandRunner.Output {
    CommandRunner.run(
      .init(
        executable: spec.executable, arguments: spec.arguments, timeout: spec.timeout,
        maximumBytes: spec.maximumBytes, input: spec.input, environment: spec.environment))
  }
}
