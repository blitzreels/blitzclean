import Testing

@testable import BlitzClean

struct ProjectProcessTests {
  @Test
  func joinsWorkingDirectoriesWithListeningPorts() {
    let processes = ProjectProcessParser.processes(
      ProcessInspectionOutput(
        workingDirectories: """
          p4776
          cnode
          fcwd
          n/Users/me/dev/project
          p9012
          cvite
          fcwd
          n/Users/me/dev/other
          """,
        listeningPorts: """
          p4776
          cnode
          f19
          n*:3333
          f20
          n127.0.0.1:61078
          p9012
          cvite
          f21
          n[::1]:5173
          """,
        processParents: """
          4776 1
          9012 400
          """
      )
    )

    #expect(processes.count == 2)
    #expect(processes[0].name == "node")
    #expect(processes[0].parentProcessID == 1)
    #expect(processes[0].listeningPorts == [3333, 61078])
    #expect(processes[1].listeningPorts == [5173])
  }
}
