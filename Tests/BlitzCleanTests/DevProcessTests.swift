import Foundation
import Testing

@testable import BlitzClean

struct DevProcessTests {
  private func record(_ arguments: String, terminal: String? = "ttys002", userID: Int = 501)
    -> RawProcessRecord
  {
    RawProcessRecord(
      processID: 100,
      parentProcessID: 1,
      userID: userID,
      cpuPercent: 1.5,
      residentKilobytes: 2_048,
      elapsed: "01:02",
      terminal: terminal,
      arguments: arguments
    )
  }

  private func classify(_ arguments: String, ports: [Int] = [], terminal: String? = "ttys002")
    -> DevProcess?
  {
    DevProcessClassifier.classify(
      DevProcessClassificationInput(
        record: record(arguments, terminal: terminal),
        listeningPorts: ports,
        workingDirectory: "/Users/me/dev/blitzreels",
        memoryBytes: nil
      )
    )
  }

  @Test
  func parsesPSRows() {
    let rows = RawProcessParser.records(
      "86146 67252   501   1.1 353680    16:53:21 ttys002  /Users/me/.local/bin/claude --session-id abc\n"
        + " 1907     1   501   0,0   8800 01-16:50:18 ??       npm run dev\n"
    )

    #expect(rows.count == 2)
    #expect(rows[0].processID == 86146)
    #expect(rows[0].terminal == "ttys002")
    #expect(rows[0].arguments == "/Users/me/.local/bin/claude --session-id abc")
    #expect(rows[1].terminal == nil)
    #expect(rows[1].cpuPercent == 0)
    #expect(rows[1].elapsed == "01-16:50:18")
  }

  @Test
  func detectsClaudeCodeSessions() {
    let process = classify(
      "/Users/me/.local/bin/claude --session-id 9fa76d0f-ad38-4285 --settings {}")

    #expect(process?.kind == .claudeCode)
    #expect(process?.detail == "session 9fa76d0f · interactive")
    #expect(process?.projectName == "blitzreels")
  }

  @Test
  func skipsClaudeChromeHelper() {
    #expect(classify("/Users/me/.local/bin/claude --chrome-native-host") == nil)
  }

  @Test
  func detectsCodexCLIAndApp() {
    let cli = classify("codex exec -s read-only do things")
    let app = classify(
      "/Applications/ChatGPT.app/Contents/Resources/codex -c x app-server", terminal: nil)
    let thread = classify(
      "/Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://",
      terminal: nil)

    #expect(cli?.kind == .codex)
    #expect(cli?.detail == "exec")
    #expect(app?.name == "Codex app")
    #expect(thread?.name == "Codex thread")
  }

  @Test
  func detectsDevServersOnlyWhenListeningOrRunningTasks() {
    let listening = classify(
      "node /Users/me/dev/app/node_modules/.bin/next dev", ports: [3000], terminal: nil)
    let nextServer = classify("next-server (v16.3.3)", ports: [3100], terminal: nil)
    let expo = classify(
      "node /Users/me/dev/mobile/node_modules/expo/bin/cli start --port 8081", ports: [8081],
      terminal: nil)
    let maestro = classify(
      "java -Xmx1g -classpath /Users/me/.maestro/lib/* maestro.cli.AppKt mcp", ports: [10001],
      terminal: nil)
    let idleNode = classify("node /Users/me/dev/app/worker.js", terminal: nil)
    let task = classify("npm run dev", terminal: nil)

    #expect(listening?.kind == .devServer)
    #expect(listening?.name == "next")
    #expect(nextServer?.name == "next-server")
    #expect(expo?.name == "expo")
    #expect(maestro?.name == "maestro")
    #expect(idleNode == nil)
    #expect(task?.kind == .devServer)
  }

  @Test
  func detectsOtherListenersAndShells() {
    let postgres = classify(
      "/opt/homebrew/bin/postgres -D /opt/homebrew/var/postgres", ports: [5432], terminal: nil)
    let guiApp = classify(
      "/Applications/Discord.app/Contents/MacOS/Discord", ports: [6463], terminal: nil)
    let shell = classify("-zsh")
    #expect(guiApp == nil)
    let scriptShell = classify("/bin/zsh -c source snapshot.sh")

    #expect(postgres?.kind == .listener)
    #expect(shell?.kind == .shell)
    #expect(scriptShell == nil)
  }

  @Test
  func summarizesCountsAndPorts() {
    let processes = [
      classify("/Users/me/.local/bin/claude --session-id a"),
      classify("/Users/me/.local/bin/claude --session-id b"),
      classify("node server.js", ports: [3000, 3001], terminal: nil),
    ].compactMap { process in process }
    let summary = DevProcessSummary(processes: processes)

    #expect(summary.claudeCount == 2)
    #expect(summary.serverCount == 1)
    #expect(summary.ports == [3000, 3001])
  }

  @Test
  func sortsFolderEntriesBySizeThenPending() {
    let entries = [
      FolderEntry(path: "/a", name: "a", isDirectory: true, isHidden: false, bytes: nil),
      FolderEntry(path: "/b", name: "b", isDirectory: true, isHidden: false, bytes: 10),
      FolderEntry(path: "/c", name: "c", isDirectory: false, isHidden: false, bytes: 30),
    ]

    #expect(FolderListingSorter.sorted(entries).map(\.name) == ["c", "b", "a"])
  }

  @Test
  func scansLiveProcessesWhenRequested() {
    guard ProcessInfo.processInfo.environment["BLITZCLEAN_LIVE_SCAN"] != nil else {
      return
    }

    let processes = DevProcessScanner().scan()
    for process in processes {
      print(
        "LIVE", process.kind.rawValue, process.name, process.detail, process.projectName ?? "-",
        process.listeningPorts, ByteText.full(process.memoryBytes), process.elapsed)
    }

    #expect(!processes.isEmpty)
  }
}
