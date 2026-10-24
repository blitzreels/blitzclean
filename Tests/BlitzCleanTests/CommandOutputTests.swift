import Foundation
import Testing

@testable import BlitzClean

/// Output captured from this Mac with read-only commands, stored under Fixtures.
private func fixture(_ name: String) throws -> String {
  let url = try #require(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))
  return try String(contentsOf: url, encoding: .utf8)
}

/// The first half of the text, as a command cut off mid-output would leave it.
private func truncated(_ text: String) -> String {
  String(text.prefix(text.count / 2))
}

private let garbage = "zsh: command not found\n<html>Service Unavailable</html>\n"

struct CommandResultTests {
  private func succeeded(_ output: String) -> CleanupCommandResult {
    .init(status: 0, output: output, failure: nil)
  }

  private func exitedOne(_ output: String) -> CleanupCommandResult {
    .init(status: 1, output: output, failure: "lsof exited with status 1")
  }

  @Test func readSeparatesFailureUnrecognisedOutputAndSuccess() {
    let parse: (String) -> Int? = { Int($0) }
    #expect(succeeded("42").read(parse) == .success(42))
    #expect(succeeded("forty-two").read(parse) == .failure(.unrecognised))
    #expect(exitedOne("42").read(parse) == .failure(.init(reason: "lsof exited with status 1")))
  }

  @Test func readMatchesTreatsOnlyASilentExitOneAsNoMatch() {
    let lines: (String) -> [Substring]? = { $0.split(separator: "\n") }
    #expect(exitedOne("").readMatches(lines) == .success([]))
    #expect(
      exitedOne("p1\n").readMatches(lines).map(\.count)
        == .failure(.init(reason: "lsof exited with status 1")))
    #expect(succeeded("a\nb").readMatches(lines).map(\.count) == .success(2))
  }

  @Test func failureNamesTheToolAndWhatWentWrong() {
    func output(_ ending: CommandRunner.Ending) -> CommandRunner.Output {
      .init(ending: ending, data: Data(), errors: "")
    }
    #expect(output(.exited(0)).failure("ps") == nil)
    #expect(
      CommandRunner.Output(
        ending: .exited(2), data: Data(), errors: "fatal: not a git repository\nmore\n"
      ).failure("git") == "git exited with status 2: fatal: not a git repository")
    #expect(output(.timedOut).failure("lsof") == "lsof did not answer in time")
    #expect(output(.outputLimit).failure("ps")?.contains("cut off") == true)
    #expect(output(.signaled).failure("ps") == "ps was stopped before it finished")
    #expect(
      CommandRunner.Output(ending: .notStarted, data: Data(), errors: "missing").failure("docker")
        == "docker could not start: missing")
  }

  @Test func requestNamesXcrunByItsSubcommand() {
    func name(_ command: [String]) -> String {
      CommandRunner.Request(
        executable: command[0], arguments: Array(command.dropFirst()), timeout: 1, maximumBytes: 1,
        input: nil, environment: .inherited
      ).name
    }
    #expect(name(["/usr/bin/xcrun", "simctl", "list"]) == "xcrun simctl")
    #expect(name(["/bin/ps", "-axo", "pid="]) == "ps")
  }

  @Test func aCommandThatTimesOutIsReportedAsUnreadNotEmpty() {
    let result = DeveloperCommand.run(
      .init(executable: "/bin/sleep", arguments: ["5"], timeout: 0.2, maximumBytes: 1_024))
    #expect(result.read { $0 } == .failure(.init(reason: "sleep did not answer in time")))
  }
}

struct ProcessListingParserTests {
  @Test func readsRealProcessRows() throws {
    let records = try #require(RawProcessParser.records(try fixture("ps-processes.txt")))
    #expect(records.count == 20)
    #expect(records[0].processID == 1 && records[0].arguments == "/sbin/launchd")
    let vite = try #require(records.first { $0.processID == 35371 })
    #expect(vite.arguments.hasSuffix("--strictPort --force"))
    #expect(records.last?.terminal == "ttys001")
  }

  @Test func processRowsRejectEmptyGarbageAndCutOffOutput() throws {
    #expect(RawProcessParser.records("") == nil)
    #expect(RawProcessParser.records(garbage) == nil)
    #expect(RawProcessParser.records("10 1 501 0 100 01:00 ?? node\n11 1 501") == nil)
    // A cut inside the last column still looks like a row, so a cut-off listing is caught by how ps ended.
    let cut = CommandRunner.Output(
      ending: .outputLimit, data: Data(truncated(try fixture("ps-processes.txt")).utf8), errors: "")
    #expect(
      cut.result("ps").read(RawProcessParser.records).map(\.count)
        == .failure(.init(reason: "ps printed more than expected, so its output was cut off")))
  }

  @Test func processTableKeepsTheLastColumnWhole() {
    let rows = ProcessTable.rows(.init(output: "  12 /Applications/A B.app/a -x  \n", columns: 2))
    #expect(rows?.first?.map(String.init) == ["12", "/Applications/A B.app/a -x"])
  }

  @Test func readsRealParents() throws {
    let parents = try #require(ProjectProcessParser.processParents(try fixture("ps-parents.txt")))
    #expect(parents[1] == 0)
    #expect(parents.count == 22)
    #expect(ProjectProcessParser.processParents("") == nil)
    #expect(ProjectProcessParser.processParents(garbage) == nil)
    #expect(ProjectProcessParser.processParents("4776 1\n9012") == nil)
  }

  @Test func readsRealArgumentsForRegrowChecks() throws {
    let listed = try #require(RegrowActivity.parse(try fixture("ps-arguments.txt")))
    #expect(listed.first == .init(processID: 1, arguments: "/sbin/launchd"))
    #expect(listed.contains { $0.arguments == "/usr/sbin/distnoted agent" })
    #expect(RegrowActivity.parse("") == nil)
    #expect(RegrowActivity.parse(garbage) == nil)
    #expect(RegrowActivity.parse("1 /sbin/launchd\n267") == nil)
  }

  @Test func readsRealCommandNamesForCacheChecks() throws {
    let names = try #require(CacheCleaner.processNames(try fixture("ps-commands.txt")))
    #expect(names.contains("launchd") && names.contains("ssh-agent"))
    #expect(CacheCleaner.processNames("") == nil)
    #expect(CacheCleaner.processNames(garbage) == nil)
    #expect(CacheCleaner.processNames("1 /sbin/launchd\n267") == nil)
  }
}

struct LsofParserTests {
  @Test func readsRealListeningPorts() throws {
    let ports = try #require(
      ProjectProcessParser.listeningPorts(try fixture("lsof-listening.txt")))
    #expect(ports[8481] == [5432])
    #expect(ports[1030] == [5000, 7000])
    #expect(ProjectProcessParser.listeningPorts("") == [:])
  }

  @Test func listeningPortsRejectGarbageAndCutOffOutput() {
    #expect(ProjectProcessParser.listeningPorts(garbage) == nil)
    #expect(ProjectProcessParser.listeningPorts("p8481\ncpostgres\nf7\nn[::1]:5432\np") == nil)
  }

  @Test func readsRealWorkingDirectories() throws {
    let directories = try #require(
      ProjectProcessParser.workingDirectories(try fixture("lsof-cwd.txt")))
    #expect(directories.count == 12)
    #expect(directories[267] == "/")
    #expect(ProjectProcessParser.workingDirectories(garbage) == nil)
    #expect(ProjectProcessParser.workingDirectories("p267\ncssh-agent\nfcwd\nn/\np2") != nil)
    #expect(ProjectProcessParser.workingDirectories("p267\ncssh-agent\nfcwd\nn/\np") == nil)
  }

  @Test func projectScanRejectsAnyUnreadableListing() {
    func scan(_ parents: String) -> [ProjectProcessInfo]? {
      ProjectProcessParser.processes(
        .init(
          workingDirectories: "p10\ncnode\nfcwd\nn/dev/app\n",
          listeningPorts: "p10\ncnode\nf3\nn*:3000\n",
          processParents: parents, identify: { _ in nil }))
    }
    #expect(scan("10 1\n")?.map(\.processID) == [10])
    #expect(scan(garbage) == nil)
    #expect(scan("") == nil)
  }
}

struct LaunchdParserTests {
  @Test func readsRealJobList() throws {
    let jobs = try #require(LeftoverProcessFinder.launchdJobs(try fixture("launchctl-list.txt")))
    #expect(jobs.contains(42830) && jobs.contains(1035))
    #expect(LeftoverProcessFinder.launchdJobs("PID\tStatus\tLabel\n") == [])
  }

  @Test func rejectsEmptyGarbageAndCutOffJobLists() throws {
    #expect(LeftoverProcessFinder.launchdJobs("") == nil)
    #expect(LeftoverProcessFinder.launchdJobs(garbage) == nil)
    #expect(LeftoverProcessFinder.launchdJobs("PID\tStatus\tLabel\n42830\t-9") == nil)
  }
}

struct GitOutputParserTests {
  @Test func readsRealWorktreeList() throws {
    let records = try #require(GitWorktrees.parse(try fixture("git-worktree-list.z")))
    #expect(records[0].primary && records[0].branch == "refs/heads/main")
    #expect(records[0].path == "/Users/me/dev/blitzreels/blitzclean")
    #expect(records.allSatisfy { $0.head.count == 40 })
    #expect(records.dropFirst().allSatisfy { $0.locked })
  }

  @Test func worktreeListRejectsEmptyGarbageAndCutOffOutput() throws {
    #expect(GitWorktrees.parse("") == nil)
    #expect(GitWorktrees.parse(garbage) == nil)
    #expect(GitWorktrees.parse("HEAD abc\0\0") == nil)
    let real = try fixture("git-worktree-list.z")
    #expect(GitWorktrees.parse(String(real.dropLast())) == nil)
    #expect(GitWorktrees.parse(truncated(real)) == nil)
  }

  @Test func readsRealBranchStatus() throws {
    let checkout = try #require(
      GitCheckoutReader.parse(
        .init(path: "/a", commonDirectory: "/a/.git", status: try fixture("git-status-branch.txt"))
      ))
    #expect(checkout.branch == "worktree-agent-ac371e77832fff86a")
    #expect(checkout.changes == 6)
  }

  @Test func branchStatusRejectsEmptyGarbageAndCutOffOutput() {
    func parse(_ status: String) -> GitCheckout? {
      GitCheckoutReader.parse(.init(path: "/a", commonDirectory: "/a/.git", status: status))
    }
    #expect(parse("") == nil)
    #expect(parse(garbage) == nil)
    #expect(parse("## main\n M") == nil)
    #expect(parse("## main\n")?.changes == 0)
  }
}

struct SimulatorParserTests {
  @Test func readsRealDeviceList() throws {
    let devices = try #require(SimulatorDeviceService.decode(try fixture("simctl-devices.json")))
    #expect(devices.count == 1)
    #expect(devices[0].name == "Test iPhone 17 Pro" && devices[0].runtime == "iOS 26.5")
    #expect(devices[0].state == "Shutdown" && devices[0].bytes == 4_374_339_584)
  }

  @Test func deviceListRejectsEmptyGarbageAndCutOffOutput() throws {
    #expect(SimulatorDeviceService.decode("") == nil)
    #expect(SimulatorDeviceService.decode(garbage) == nil)
    #expect(SimulatorDeviceService.decode(truncated(try fixture("simctl-devices.json"))) == nil)
  }

  @Test func readsRealRuntimeList() throws {
    let copies = try #require(SimulatorRuntimeCopies.read(try fixture("simctl-runtimes.json")))
    #expect(copies.map(\.build) == ["23F77"])
    #expect(
      copies[0].uses(
        "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/26c9174130fa5962f3e60f2a49963194dadbae4c.asset"
      ))
    #expect(SimulatorRuntimeCopies.read("{}") == [])
  }

  @Test func runtimeListRejectsEmptyGarbageAndCutOffOutput() throws {
    #expect(SimulatorRuntimeCopies.read("") == nil)
    #expect(SimulatorRuntimeCopies.read(garbage) == nil)
    #expect(SimulatorRuntimeCopies.read(truncated(try fixture("simctl-runtimes.json"))) == nil)
  }

  @Test func aFailedDeviceListSaysWhy() {
    let service = SimulatorDeviceService { _ in
      .init(status: -1, output: "", failure: "xcrun simctl did not answer in time")
    }
    #expect(throws: SimulatorDeviceService.Failure.self) { try service.list() }
    do {
      _ = try service.list()
    } catch {
      #expect(error.localizedDescription.contains("xcrun simctl did not answer in time"))
    }
  }
}

struct DockerParserTests {
  @Test func readsRealStorageReport() throws {
    let categories = try DockerStorageParser.categories(try fixture("docker-system-df.jsonl"))
    #expect(categories.map(\.id) == ["images", "build-cache", "containers", "volumes"])
    #expect(categories[0].sizeBytes == 6_890_000_000)
  }

  @Test func storageReportRejectsEmptyGarbageAndCutOffOutput() throws {
    #expect(throws: DockerStorageError.invalidOutput) { try DockerStorageParser.categories("") }
    #expect(throws: (any Error).self) { try DockerStorageParser.categories(garbage) }
    let real = try fixture("docker-system-df.jsonl")
    #expect(throws: (any Error).self) { try DockerStorageParser.categories(truncated(real)) }
  }

  @Test func readsRealDanglingImages() throws {
    #expect(
      DockerStorageParser.danglingBytes(try fixture("docker-dangling-images.jsonl"))
        == 1_790_000_000)
    #expect(DockerStorageParser.danglingBytes("") == 0)
    #expect(DockerStorageParser.danglingBytes(garbage) == nil)
    #expect(DockerStorageParser.danglingBytes("{\"ID\":\"abc\",\"Size\":\"50") == nil)
  }

  @Test func readsRealContainerInspection() throws {
    let containers = try DockerProjectService.parse(try fixture("docker-inspect.jsonl"))
    #expect(containers.count == 1)
    #expect(containers[0].running && !containers[0].paused)
    #expect(containers[0].directory == "/Users/me/dev/sample-app/infra/sample-app")
    #expect(try DockerProjectService.parse("").isEmpty)
    #expect(throws: (any Error).self) { try DockerProjectService.parse(garbage) }
    let real = try fixture("docker-inspect.jsonl")
    #expect(throws: (any Error).self) { try DockerProjectService.parse(truncated(real)) }
  }
}

struct GitSafetyTests {
  @Test func repositoryFsmonitorCommandNeverRuns() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fsmonitor-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("ran")
    #expect(
      DeveloperCommand.git(.init(directory: root.path, arguments: ["init", "-q"])).status == 0)
    #expect(
      DeveloperCommand.git(
        .init(
          directory: root.path,
          arguments: ["config", "core.fsmonitor", "touch '\(marker.path)'; false"])
      ).status == 0)
    _ = DeveloperCommand.git(.init(directory: root.path, arguments: ["status", "--porcelain=v1"]))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }
}

struct GitFilterTests {
  @Test func repositoryCleanFilterNeverRunsDuringStatus() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("filter-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("ran")
    let file = root.appendingPathComponent("a.txt")
    func git(_ arguments: [String]) -> Int32 {
      DeveloperCommand.git(.init(directory: root.path, arguments: arguments)).status
    }
    #expect(git(["init", "-q"]) == 0)
    try "hi\n".write(to: file, atomically: true, encoding: .utf8)
    #expect(git(["add", "a.txt"]) == 0)
    #expect(git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "x"]) == 0)
    try "* filter=evil\n".write(
      to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    #expect(git(["config", "filter.evil.clean", "touch '\(marker.path)'; cat"]) == 0)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)], ofItemAtPath: file.path)
    _ = git(["status", "--porcelain=v1"])
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test func onlyRepositoryScopedFiltersAreOverridden() {
    let listed = CleanupCommandResult(
      status: 0,
      output: "global\tfilter.lfs.clean git-lfs clean -- %f\nlocal\tfilter.evil.clean x\n"
        + "worktree\tfilter.a.b.smudge y\n",
      failure: nil)
    #expect(GitFilters.repositoryNames(listed) == ["evil", "a.b"])
    #expect(
      GitFilters.repositoryNames(.init(status: 1, output: "", failure: "git exited with status 1"))
        == [])
  }

  @Test func unoverridableOrUnreadableFiltersStopGit() {
    #expect(
      GitFilters.repositoryNames(
        .init(status: 0, output: "local\tfilter.a=b.clean x\n", failure: nil)) == nil)
    #expect(
      GitFilters.repositoryNames(.init(status: 128, output: "", failure: "fatal")) == nil)
  }
}

struct GitScopeTests {
  private struct Repository {
    let root: URL
    let repository: URL
    let marker: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("git-scope-\(UUID())")
      repository = root.appendingPathComponent("repo")
      marker = root.appendingPathComponent("ran")
      try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
      try "hi\n".write(
        to: repository.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
      try "* filter=evil\n".write(
        to: repository.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    }

    func git(_ directory: URL, _ arguments: [String]) -> Int32 {
      DeveloperCommand.git(.init(directory: directory.path, arguments: arguments)).status
    }

    func commit(_ directory: URL) {
      _ = git(directory, ["add", "."])
      _ = git(directory, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "x"])
    }

    func makeStale(_ file: URL) throws {
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)], ofItemAtPath: file.path)
    }
  }

  @Test func worktreeScopedFilterNeverRunsDuringRemove() throws {
    let fixture = try Repository()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let tree = fixture.root.appendingPathComponent("tree")
    #expect(fixture.git(fixture.repository, ["init", "-q"]) == 0)
    fixture.commit(fixture.repository)
    #expect(fixture.git(fixture.repository, ["worktree", "add", "-q", tree.path]) == 0)
    #expect(fixture.git(fixture.repository, ["config", "extensions.worktreeConfig", "true"]) == 0)
    #expect(
      fixture.git(
        tree, ["config", "--worktree", "filter.evil.clean", "touch '\(fixture.marker.path)'; cat"])
        == 0)
    try fixture.makeStale(tree.appendingPathComponent("a.txt"))
    let safety = try #require(
      DeveloperCommand.gitArguments([fixture.repository.path, tree.path]))
    _ = DeveloperCommand.run(
      .init(
        executable: "/usr/bin/git",
        arguments: safety + ["-C", fixture.repository.path, "worktree", "remove", "--", tree.path],
        timeout: 30, maximumBytes: 65_536))
    #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
  }

  @Test func submoduleFilterNeverRunsDuringStatus() throws {
    let fixture = try Repository()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let parent = fixture.root.appendingPathComponent("parent")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    #expect(fixture.git(fixture.repository, ["init", "-q"]) == 0)
    fixture.commit(fixture.repository)
    #expect(fixture.git(parent, ["init", "-q"]) == 0)
    #expect(
      fixture.git(
        parent,
        [
          "-c", "protocol.file.allow=always", "submodule", "add", "-q", fixture.repository.path,
          "sub",
        ])
        == 0)
    fixture.commit(parent)
    let submodule = parent.appendingPathComponent("sub")
    #expect(
      fixture.git(
        submodule, ["config", "filter.evil.clean", "touch '\(fixture.marker.path)'; cat"])
        == 0)
    try fixture.makeStale(submodule.appendingPathComponent("a.txt"))
    _ = GitCheckoutReader.read(parent.path)
    #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
  }
}
