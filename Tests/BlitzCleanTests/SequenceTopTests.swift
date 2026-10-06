import Testing

@testable import BlitzClean

struct SequenceTopTests {
  @Test func returnsLargestFirstWithoutSortingEverything() {
    let values = [4, 9, 1, 7, 9, 3, 12, 0]
    #expect(values.largest(.init(count: 3, key: { $0 })) == [12, 9, 9])
    #expect(values.largest(.init(count: 20, key: { $0 })) == values.sorted(by: >))
    #expect(values.largest(.init(count: 0, key: { $0 })).isEmpty)
    #expect([Int]().largest(.init(count: 3, key: { $0 })).isEmpty)
  }

  @Test func ranksByTheGivenKey() {
    let names = ["bb", "a", "dddd", "ccc"]
    #expect(names.largest(.init(count: 2, key: \.count)) == ["dddd", "ccc"])
  }
}
