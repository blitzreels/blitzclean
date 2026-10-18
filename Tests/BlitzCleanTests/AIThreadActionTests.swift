import Testing

@testable import BlitzClean

@MainActor
struct AIThreadActionTests {
  @Test func pausedPrimaryActionResumesAndRunningPrimaryActionStops() {
    var resumed = 0
    var stopped = 0
    for paused in [true, false] {
      for busy in [true, false] {
        let row = AIThreadRow(
          thread: AIThread(
            id: "codex", tool: .codexDesktop, name: "Codex workers", directory: nil,
            terminal: nil, startedAt: nil, processIDs: [42], memoryBytes: 1000,
            cpuPercent: 0, isPaused: paused, isDetached: false),
          isBusy: busy, onPause: {}, onResume: { resumed += 1 },
          onQuit: { stopped += 1 }, onForceQuit: {})
        let button = row.primaryButton
        #expect(button.title == (paused ? "Resume" : "Stop"))
        #expect(button.label == "\(paused ? "Resume" : "Stop") Codex workers")
        #expect(button.isBusy == busy)
        if !busy { button.action() }
      }
    }
    #expect(resumed == 1)
    #expect(stopped == 1)
  }
}
