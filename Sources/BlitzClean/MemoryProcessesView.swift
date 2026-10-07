import SwiftUI

enum MemoryListingMode: String, CaseIterable {
  case apps = "Apps & AI"
  case processes = "Processes"
}

enum MemoryProcessRanking {
  struct Input {
    let processes: [ResourceProcess]
    let query: String
  }

  static func ranked(_ input: Input) -> [ResourceProcess] {
    let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
    return input.processes.filter { process in
      query.isEmpty
        || [process.name, process.owner, String(process.processID), process.directory ?? ""]
          .contains { $0.localizedCaseInsensitiveContains(query) }
    }.sorted { left, right in
      switch (left.memoryBytes, right.memoryBytes) {
      case (.some(let lhs), .some(let rhs)):
        return lhs == rhs ? left.processID < right.processID : lhs > rhs
      case (.some, .none): return true
      case (.none, .some): return false
      case (.none, .none): return left.processID < right.processID
      }
    }
  }
}

struct MemoryProcessesView: View {
  let processes: [ResourceProcess]
  let isLoading: Bool
  let query: String
  let scanMessage: String?
  @State private var showsAll = false

  var body: some View {
    let ranked = MemoryProcessRanking.ranked(.init(processes: processes, query: query))
    let visible = showsAll || !query.isEmpty ? ranked : Array(ranked.prefix(30))
    return VStack(alignment: .leading, spacing: 10) {
      BlitzSectionHeader(title: "Memory by process", count: ranked.count) {
        Text("Largest first").font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText)
      }
      Text("Your user account · each PID shown once · memory footprint, without child processes.")
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      if let scanMessage { BlitzStatusLine(text: scanMessage, tone: .warning) }
      LazyVStack(spacing: 0) {
        if visible.isEmpty {
          BlitzEmptyRow(
            text: isLoading ? "Reading process memory…" : "No matching processes",
            isLoading: isLoading)
        }
        ForEach(visible) { process in
          HStack(spacing: 12) {
            ApplicationIcon(source: .process(process.processID), size: 28, fallback: "terminal")
            VStack(alignment: .leading, spacing: 3) {
              Text(process.name).font(BlitzType.rowTitle).lineLimit(1)
              Text("\(process.owner) · PID \(process.processID)")
                .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            BlitzTrailingValue(
              value: process.memoryBytes.map(ByteText.full) ?? "—",
              detail: process.memoryBytes == nil ? "Unavailable" : nil)
          }.blitzRow()
            .help(process.directory ?? "Background process")
          if process.id != visible.last?.id { BlitzRowDivider(leading: 56) }
        }
      }.blitzTable()
      if ranked.count > 30 && query.isEmpty {
        BlitzShowAllButton(total: ranked.count, noun: "processes", isExpanded: $showsAll)
      }
      Text("Restricted readings show —. Process footprints do not add up to total system RAM.")
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
    }
  }
}
