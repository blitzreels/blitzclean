import Foundation
import Testing

@testable import BlitzClean

struct DockerStorageTests {
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
