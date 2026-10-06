import Foundation
import Testing

@testable import BlitzClean

struct AIThreadsTests {
  private func record(_ pid: Int32, _ ppid: Int32, _ args: String, tty: String? = nil)
    -> RawProcessRecord
  {
    RawProcessRecord(
      processID: pid, parentProcessID: ppid, userID: 501, cpuPercent: 1, residentKilobytes: 1,
      elapsed: "01:00", terminal: tty, arguments: args)
  }

  private func input(_ records: [RawProcessRecord], starts: [Int32: TimeInterval] = [:])
    -> AIThreadInput
  {
    AIThreadInput(
      records: records,
      directories: [
        10: "/Users/me/dev/app", 31: "/Users/me/dev/api", 41: "/Users/me/dev/web", 50: "/Users/me",
      ],
      footprints: Dictionary(uniqueKeysWithValues: records.map { ($0.processID, UInt64(100)) }),
      startTimes: starts, home: "/Users/me")
  }

  @Test func executableNamesSurviveSpacesInPaths() {
    #expect(
      AIThreadGrouping.executableName(
        "/Users/me/Library/Application Support/Cursor/bin/cursor-agent --use-system-ca /x/index.js")
        == "cursor-agent")
    #expect(
      AIThreadGrouping.executableName("/Applications/ChatGPT.app/Contents/MacOS/codex app-server")
        == "codex")
    #expect(AIThreadGrouping.executableName("npm exec mcp-remote https://x.test/mcp/") == "npm")
    #expect(AIThreadGrouping.executableName("node /Users/me/.bin/server.js") == "node")
    #expect(AIThreadGrouping.executableName("-/bin/zsh") == "zsh")
  }

  @Test func shellCommandsAreNamedByWhatTheyRun() {
    #expect(
      AIThreadGrouping.shellCommand(
        "/bin/bash -c lsof -nP -iTCP:3100; PATH=/x/bin:$PATH pnpm app:dev > /tmp/a.log 2>&1")
        == "pnpm app:dev")
    #expect(AIThreadGrouping.shellCommand("/bin/zsh -c cd /x && npm run dev") == "npm run")
    #expect(AIThreadGrouping.shellCommand("node server.js") == nil)
  }

  @Test func hiddenToolFoldersAreNotProjects() {
    let threads = AIThreadGrouping.threads(
      AIThreadInput(
        records: [
          record(10, 1, "/Users/me/.local/bin/claude"),
          record(11, 10, "node ./server.mjs"),
        ],
        directories: [10: "/Users/me/.codex/plugins/x/1.0.1", 11: "/Users/me/dev/site"],
        footprints: [:], startTimes: [:], home: "/Users/me"))
    #expect(threads.first?.project == "site")
  }

  @Test func claudeSessionIncludesItsToolServersAndProject() {
    let threads = AIThreadGrouping.threads(
      input([
        record(9, 1, "-/bin/zsh", tty: "ttys001"),
        record(10, 9, "/Users/me/.local/bin/claude --session-id abc", tty: "ttys001"),
        record(11, 10, "node /Users/me/mcp/server.js"),
        record(12, 11, "/opt/homebrew/bin/uv tool run analytics-mcp"),
        record(13, 1, "/Users/me/.local/bin/claude --chrome-native-host"),
      ]))
    #expect(threads.count == 1)
    let thread = try? #require(threads.first)
    #expect(thread?.tool == .claudeCode)
    #expect(Set(thread?.processIDs ?? []) == [10, 11, 12])
    #expect(thread?.memoryBytes == 300)
    #expect(thread?.project == "app")
    #expect(thread?.terminal == "ttys001")
    #expect(thread?.isDetached == false)
  }

  @Test func nestedAgentsBelongToTheOuterSession() {
    let threads = AIThreadGrouping.threads(
      input([
        record(10, 1, "/Users/me/.local/bin/claude"),
        record(11, 10, "/usr/local/bin/codex exec fix"),
      ]))
    #expect(threads.map(\.processIDs.count) == [2])
    #expect(threads.first?.delegatedTools == ["Codex CLI"])
    #expect(threads.first?.identityDetail.contains("includes Codex CLI") == true)
  }

  @Test func orphanedCursorAgentIsDetached() {
    let threads = AIThreadGrouping.threads(
      input([
        record(31, 1, "/Users/me/Library/Application Support/Cursor/cursor-agent --use-system-ca"),
        record(32, 31, "/usr/bin/java -classpath maestro.cli.AppKt mcp"),
      ]))
    #expect(threads.first?.tool == .cursorAgent)
    #expect(threads.first?.isDetached == true)
    #expect(threads.first?.project == "api")
  }

  @Test func nestedCodexHostDoesNotDoubleCountClaudeWorkers() {
    let threads = AIThreadGrouping.threads(
      input([
        record(10, 1, "claude"),
        record(11, 10, "codex app-server"),
        record(12, 11, "node mcp"),
      ]))
    #expect(threads.count == 1)
    #expect(Set(threads.first?.processIDs ?? []) == [10, 11, 12])
    #expect(threads.first?.memoryBytes == 300)
  }

  @Test func desktopCodexChildrenSplitIntoThreadsByLaunchTime() {
    let host = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/codex app-server --analytics"
    let threads = AIThreadGrouping.threads(
      input(
        [
          record(1, 0, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
          record(40, 1, host),
          record(41, 40, "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"),
          record(42, 40, "npm exec xcodebuildmcp@latest mcp"),
          record(43, 40, "agent-browser mcp"),
          record(44, 41, "/Applications/ChatGPT.app/Contents/codex app-server --listen stdio://"),
          record(50, 40, "/bin/bash -c pnpm dev"),
          record(60, 40, "node_repl"),
          record(61, 40, "npm exec @upstash/context7-mcp"),
          record(62, 40, "agent-browser mcp"),
        ],
        starts: [41: 100, 42: 101, 43: 104, 44: 105, 50: 300, 60: 900, 61: 902, 62: 903]))
    #expect(threads.count == 3)
    #expect(threads.allSatisfy { $0.tool == .codexDesktop })
    let first = threads.first { $0.processIDs.contains(41) }
    #expect(Set(first?.processIDs ?? []) == [41, 42, 43, 44])
    #expect(first?.name == "Codex workers")
    #expect(first?.project == "web")
    #expect(threads.first { $0.processIDs == [50] }?.name == "Codex · pnpm dev")
    #expect(!threads.contains { $0.processIDs.contains(40) })
  }

  @Test func pausedWhenEveryProcessIsStopped() {
    let threads = AIThreadGrouping.threads(
      AIThreadInput(
        records: [record(10, 1, "/Users/me/.local/bin/claude"), record(11, 10, "node mcp")],
        directories: [10: "/Users/me/dev/app"], footprints: [10: 100, 11: 50],
        startTimes: [:], home: "/Users/me", stoppedIDs: [10, 11]))
    #expect(threads.first?.isPaused == true)
    let running = AIThreadGrouping.threads(input([record(10, 1, "/Users/me/.local/bin/claude")]))
    #expect(running.first?.isPaused == false)
  }

  @Test func pauseAndResumeSignalsALiveProcess() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["20"]
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    let pid = child.processIdentifier
    let identity = try #require(DevProcessIdentity.read(pid))
    let thread = AIThread(
      id: "sleep", tool: .otherAgent, name: "sleep", directory: nil, terminal: nil,
      startedAt: nil, processIDs: [pid], memoryBytes: 1, cpuPercent: 0, isPaused: false,
      isDetached: false)
    let request = AIThreadStopRequest(thread: thread, expected: [pid: identity], force: false)
    #expect(AIThreadStopper.signal(request, .pause) == 1)
    #expect(AIThreadStopper.paused(request))
    #expect(child.isRunning)
    #expect(AIThreadStopper.signal(request, .resume) == 1)
    #expect(!AIThreadStopper.paused(request))
    #expect(AIThreadStopper.running(request))
  }

  @Test func largestThreadComesFirst() {
    var records = [record(10, 1, "/Users/me/.local/bin/claude")]
    records.append(record(20, 1, "/usr/local/bin/codex"))
    records.append(record(21, 20, "node mcp"))
    let threads = AIThreadGrouping.threads(input(records))
    #expect(threads.map(\.tool) == [.codexCLI, .claudeCode])
  }

  @Test func cmuxIsHostAndClaudeOwnsDelegatedCodex() {
    let threads = AIThreadGrouping.threads(
      input([
        record(8, 1, "/Applications/cmux.app/Contents/MacOS/cmux"),
        record(9, 8, "-/bin/zsh", tty: "ttys001"),
        record(10, 9, "claude", tty: "ttys001"),
        record(11, 10, "codex exec fix"),
        record(12, 11, "node mcp"),
      ]))
    #expect(threads.count == 1)
    #expect(threads.first?.tool == .claudeCode)
    #expect(threads.first?.hostName == "cmux")
    #expect(threads.first?.delegatedTools == ["Codex CLI"])
    #expect(Set(threads.first?.processIDs ?? []) == [10, 11, 12])
  }

  @Test func quittingPausedProcessDeliversTermination() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["20"]
    try child.run()
    let pid = child.processIdentifier
    defer {
      if child.isRunning {
        _ = Darwin.kill(pid, SIGCONT)
        child.terminate()
      }
    }
    let identity = try #require(DevProcessIdentity.read(pid))
    let thread = AIThread(
      id: "sleep", tool: .otherAgent, name: "sleep", directory: nil, terminal: nil,
      startedAt: nil, processIDs: [pid], memoryBytes: 1, cpuPercent: 0, isPaused: false,
      isDetached: false)
    let request = AIThreadStopRequest(thread: thread, expected: [pid: identity], force: false)
    #expect(AIThreadStopper.signal(request, .pause) == 1)
    for _ in 0..<20 where !AIThreadStopper.paused(request) {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(AIThreadStopper.paused(request))
    #expect(AIThreadStopper.signal(request, .quit) == 1)
    for _ in 0..<40 where AIThreadStopper.running(request) {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(!AIThreadStopper.running(request))
  }

  @Test func liveGroupingWhenRequested() {
    guard ProcessInfo.processInfo.environment["BLITZCLEAN_LIVE_THREADS"] != nil else { return }
    for thread in DevProcessScanner().snapshot().threads {
      print(
        "THREAD", thread.displayName, thread.identityDetail, thread.processIDs.count,
        ByteText.full(thread.memoryBytes), thread.isDetached ? "detached" : "",
        thread.terminal ?? "")
    }
  }
}
