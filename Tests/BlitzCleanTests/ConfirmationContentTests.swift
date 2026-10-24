import Testing

@testable import BlitzClean

struct ConfirmationContentTests {
  @Test func listLinesBecomeItemsWithTheirSizes() {
    let content = ConfirmationContent.parse(
      "App caches · 4,1 GB\nLogs · 443,5 MB\n\nUp to 4,5 GB is permanently deleted.")
    #expect(
      content.items == [
        .init(name: "App caches", value: "4,1 GB"), .init(name: "Logs", value: "443,5 MB"),
      ])
    #expect(content.note == "Up to 4,5 GB is permanently deleted.")
  }

  @Test func pathsWithoutSizesAreItemsAndPlainTextIsANote() {
    #expect(
      ConfirmationContent.parse("/a\n/b\n\nGit checks each.").items.map(\.value) == [nil, nil])
    let plain = ConfirmationContent.parse("It ends immediately and cannot save its work.")
    #expect(plain.items.isEmpty)
    #expect(plain.note == "It ends immediately and cannot save its work.")
  }
}
