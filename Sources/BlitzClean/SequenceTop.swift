struct LargestQuery<Element, Key: Comparable> {
  let count: Int
  let key: (Element) -> Key
}

extension Sequence {
  /// The `count` largest elements by `key`, largest first, without sorting the whole sequence.
  func largest<Key: Comparable>(_ query: LargestQuery<Element, Key>) -> [Element] {
    guard query.count > 0 else { return [] }
    var top: [Element] = []
    top.reserveCapacity(query.count + 1)
    for element in self {
      let value = query.key(element)
      if top.count == query.count, let last = top.last, value <= query.key(last) { continue }
      let index = top.firstIndex { query.key($0) < value } ?? top.endIndex
      top.insert(element, at: index)
      if top.count > query.count { top.removeLast() }
    }
    return top
  }
}
