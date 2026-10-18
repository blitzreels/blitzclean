import Foundation
import Testing

@testable import BlitzClean

struct ProcessOriginTests {
  @Test func namesRenderBrowsersByTheProjectThatInstalledThem() {
    let match = ProcessOrigin.tool(
      executable:
        "/Volumes/harddrive/dev/blitzreels/media/node_modules/.remotion/chrome-headless-shell/mac-arm64/chrome-headless-shell-mac-arm64/chrome-headless-shell"
    )
    #expect(match == .init(tool: "Remotion render browser", project: "media"))
    #expect(ProcessOrigin.tool(executable: "/Applications/Safari.app/Contents/MacOS/Safari") == nil)
  }

  @Test func readsItsOwnProcess() {
    let origin = ProcessOrigin.read(getpid())
    #expect(origin?.chain.isEmpty == false)
    #expect(origin?.orphaned == false)
  }
}
