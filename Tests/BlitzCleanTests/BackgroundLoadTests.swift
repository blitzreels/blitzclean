import Foundation
import Testing

@testable import BlitzClean

struct BackgroundLoadTests {
  private let mib: UInt64 = 1_024 * 1_024

  private func service(_ input: (keepAlive: Bool, interval: TimeInterval?)) -> LaunchService {
    LaunchService(
      label: "com.example.job", plist: "/tmp/com.example.job.plist", command: "run.sh",
      keepAlive: input.keepAlive, runAtLoad: true, interval: input.interval, calendar: false)
  }

  @Test func launchctlListKeepsRunningAndExitedServices() {
    let output = "PID\tStatus\tLabel\n1099\t0\tcom.algomax.openseo\n-\t127\tcom.virgile.sync\n"
    let states = BackgroundLoadParser.launchStates(output)
    #expect(states["com.algomax.openseo"] == .init(processID: 1099, status: 0))
    #expect(states["com.virgile.sync"] == .init(processID: nil, status: 127))
  }

  @Test func commandSkipsShellWrappers() {
    #expect(
      LaunchService.command(["/bin/bash", "-lc", "/Users/a/bin/algomax-studios-run.sh"])
        == "algomax-studios-run.sh")
    #expect(LaunchService.command(["/opt/homebrew/opt/postgresql@15/bin/postgres"]) == "postgres")
  }

  @Test func alwaysOnServiceAboveTheFloorIsNamed() {
    let running = LaunchState(processID: 1099, status: 0)
    let large = BackgroundLoadRules.service(
      .init(service: service((true, nil)), state: running, memory: 1_100 * mib))
    #expect(large?.kind == .loginService)
    #expect(large?.detail.hasPrefix("Starts at login and restarts") == true)
    let small = BackgroundLoadRules.service(
      .init(service: service((true, nil)), state: running, memory: 50 * mib))
    #expect(small == nil)
  }

  @Test func recurringJobThatFailsIsNamedWithItsReason() {
    let finding = BackgroundLoadRules.service(
      .init(
        service: service((false, 900)), state: .init(processID: nil, status: 127), memory: 0))
    #expect(finding?.kind == .failingJob)
    #expect(finding?.detail.contains("every 15 min · command not found") == true)
  }

  @Test func toolKeysNameTheToolPastLaunchersAndFlags() {
    #expect(
      BackgroundLoadParser.toolKey("npm exec xcodebuildmcp@latest mcp") == "xcodebuildmcp mcp")
    #expect(
      BackgroundLoadParser.toolKey(
        "npm exec mcp-remote https://studios.algomax.fr/mcp --header Authorization: Bearer x")
        == "mcp-remote studios.algomax.fr")
    #expect(
      BackgroundLoadParser.toolKey(
        "/opt/homebrew/bin/uv tool uvx --with mcp<2 --from freshservice-mcp freshservice-mcp")
        == "freshservice-mcp")
    #expect(
      BackgroundLoadParser.toolKey(
        "/opt/java -classpath /Users/a/.maestro/lib/* maestro.cli.AppKt mcp")
        == "maestro mcp")
  }

  @Test func toolsNeedThreeSessionsBeforeTheyCount() {
    let copies = (0..<5).map {
      BackgroundLoadRules.ToolCopy(key: "java maestro", session: Int32($0), bytes: 200 * mib)
    }
    #expect(BackgroundLoadRules.agentTools(copies).first?.value == ByteText.compact(1_000 * mib))
    #expect(BackgroundLoadRules.agentTools(Array(copies.prefix(2))).isEmpty)
  }

  @Test func diskWriteReportsParseAndOnlyHeavyOnesShow() throws {
    let text = """
      Command:          ChatGPT
      Event:            disk writes
      Writes:           137.44 GB of file backed memory dirtied over 54163 seconds (2537.50 KB per second average)
      """
    let write = try #require(BackgroundLoadParser.diskWrite(text))
    #expect(write == .init(command: "ChatGPT", path: "", bytes: 137_440_000_000, seconds: 54_163))
    let helper = BackgroundLoadParser.DiskWrite(
      command: "Google Chrome Helper", path: "/Applications/Google Chrome.app/Contents/Helper",
      bytes: 34_360_000_000, seconds: 100)
    let system = BackgroundLoadParser.DiskWrite(
      command: "mds_stores", path: "/System/Library/mds_stores", bytes: 34_360_000_000, seconds: 100
    )
    let light = BackgroundLoadParser.DiskWrite(
      command: "cfprefsd", path: "/Applications/X.app/x", bytes: 8_589_000_000, seconds: 100)
    let findings = BackgroundLoadRules.ordered(
      BackgroundLoadRules.diskWriters(
        .init(reports: [
          ("/r/a.diag", .now, write), ("/r/b.diag", .now, write), ("/r/c.diag", .now, light),
          ("/r/d.diag", .now, helper), ("/r/e.diag", .now, system),
        ])))
    #expect(findings.map(\.title) == ["ChatGPT", "Google Chrome"])
    #expect(findings.first?.detail.contains("15 h") == true)
    #expect(findings.first?.detail.contains("2 times") == true)
  }
}
