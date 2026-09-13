import AppKit
import SwiftUI

struct MemoryControlView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var model: MemoryRescueModel
  @State private var selected: Set<Int32> = []
  @State private var query = ""
  @State private var seconds = 300.0
  @State private var pending: [MemoryApp] = []
  @State private var releasing = false
  @State private var result: String?
  @State private var showProtected = true

  private var selectedApps: [MemoryApp] {
    model.suggestions.map(\.app).filter { selected.contains($0.id) }
  }

  private var visibleCandidates: [MemoryCandidate] {
    model.candidates.filter {
      (showProtected || !$0.protected)
        && (query.isEmpty || $0.app.name.localizedCaseInsensitiveContains(query))
    }.sorted { $0.app.memoryBytes > $1.app.memoryBytes }
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(ByteText.full(monitor.snapshot.ramUsed)).font(
                .system(size: 32, weight: .semibold)
              ).monospacedDigit()
              Text("of \(ByteText.full(monitor.snapshot.ramTotal)) used").foregroundStyle(
                .secondary)
              Spacer()
              HistoryRangePicker(seconds: $seconds)
            }
            ResourcePlot(
              samples: monitor.resourceSamples, kind: .memory, color: AppBrand.accent,
              seconds: seconds
            ).frame(height: 100)
            HStack(spacing: 24) {
              memoryStat(
                .init(title: "Available", value: ByteText.compact(monitor.snapshot.ramAvailable)))
              memoryStat(
                .init(title: "Swap", value: model.sample?.swapUsed.map(ByteText.compact) ?? "—"))
              memoryStat(.init(title: "Pressure", value: model.pressure.title))
            }
            DisclosureGroup("Memory details") {
              VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 24) {
                  memoryStat(
                    .init(
                      title: "Compressed",
                      value: model.sample.map { ByteText.compact($0.compressed) } ?? "—"))
                  memoryStat(
                    .init(
                      title: "Wired",
                      value: monitor.memoryStats.map { ByteText.compact($0.wired) } ?? "—"))
                }
                Text(
                  "Available RAM includes reclaimable caches. App footprints include helpers and swapped memory; they do not add up to physical RAM used."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
              }.padding(.top, 10)
            }.font(.system(size: 12)).foregroundStyle(.secondary)
          }.panelCard(padding: 20)
          HStack {
            BlitzSearchField(title: "Search apps", text: $query).frame(
              maxWidth: 260)
            Toggle("Show protected", isOn: $showProtected).toggleStyle(.checkbox)
            Spacer()
            Button("Refresh") { model.refresh() }
              .disabled(model.isRefreshing || releasing)
          }
          if let result = result ?? model.statusMessage {
            Text(result).font(.callout).textSelection(.enabled).panelCard()
          }
          if visibleCandidates.isEmpty {
            ContentUnavailableView(
              model.isRefreshing
                ? "Reading running apps" : query.isEmpty ? "No apps to review" : "No matching apps",
              systemImage: "memorychip"
            ).frame(maxWidth: .infinity)
          }
          LazyVStack(spacing: 0) {
            ForEach(visibleCandidates) { candidate in
              HStack(spacing: 12) {
                Toggle(
                  "Select \(candidate.app.name)",
                  isOn: Binding(
                    get: { selected.contains(candidate.id) },
                    set: {
                      if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                    })
                )
                .labelsHidden().toggleStyle(.checkbox).disabled(candidate.protected || releasing)
                AppMemoryIcon(app: candidate.app)
                VStack(alignment: .leading, spacing: 4) {
                  Text(candidate.app.name).font(.callout.weight(.semibold))
                  if candidate.protected {
                    Text(candidate.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                  Text(ByteText.full(candidate.app.memoryBytes)).font(.callout.weight(.semibold))
                    .monospacedDigit()
                }.frame(minWidth: 90)
              }.help("\(candidate.reason) · \(candidate.app.childProcessCount) helpers").padding(
                .vertical, 12)
              Divider()
            }
          }
        }.padding(24)
      }
      Divider()
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          Text(
            selectedApps.isEmpty
              ? "Select apps to release RAM"
              : "\(selectedApps.count) selected · \(ByteText.full(selectedApps.reduce(0) { $0 + $1.memoryBytes })) footprint"
          )
          .font(.callout.weight(.semibold))
          Text("Apps receive a normal quit request.").font(.caption).foregroundStyle(
            .secondary)
        }
        Spacer()
        if releasing { ProgressView().controlSize(.small) }
        Button(releasing ? "Releasing…" : "Free RAM…") { pending = selectedApps }
          .buttonStyle(BlitzButtonStyle(.accent)).controlSize(.large)
          .disabled(selectedApps.isEmpty || releasing)
      }.padding(.horizontal, 24).padding(.vertical, 14).background(BlitzUI.sidebarBackground)
    }
    .task { model.refresh() }
    .confirmationDialog(
      "Quit \(pending.count) selected app(s)?",
      isPresented: Binding(
        get: { !pending.isEmpty }, set: { if !$0 { pending = [] } }), titleVisibility: .visible
    ) {
      Button("Quit selected apps", role: .destructive) {
        let apps = pending
        pending = []
        release(apps)
      }
      Button("Cancel", role: .cancel) { pending = [] }
    } message: {
      Text(
        pending.map(\.name).joined(separator: ", ")
          + " will receive a normal quit request. Save dialogs are respected. These apps stay closed; their memory recovery varies."
      )
    }
  }

  private struct Stat {
    let title: String
    let value: String
  }

  private func memoryStat(_ input: Stat) -> some View {
    HStack {
      Text(input.title).font(.system(size: 12)).foregroundStyle(.secondary)
      Spacer()
      Text(input.value).font(.system(size: 12, weight: .medium)).monospacedDigit()
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func release(_ apps: [MemoryApp]) {
    releasing = true
    result = nil
    let before = MemoryGuardSample.read(pressure: MemoryPressureReader().current())
    Task {
      var closed = 0
      for app in apps {
        await model.quitAndKeepClosed(app)
        if NSRunningApplication(processIdentifier: app.id)?.isTerminated != false { closed += 1 }
        result = model.statusMessage
      }
      monitor.refresh()
      let after = MemoryGuardSample.read(pressure: MemoryPressureReader().current())
      let change = before.flatMap { old in
        after.map { Int64(clamping: $0.available) - Int64(clamping: old.available) }
      }
      result =
        "\(closed) of \(apps.count) apps closed. "
        + (change.map {
          "Available RAM changed by \($0 >= 0 ? "+" : "−")\(ByteText.full(UInt64(abs($0)))). "
        } ?? "RAM measurement unavailable. ")
        + "Other activity affects this reading.\(closed < apps.count ? " Remaining apps were protected, declined, or need a save response." : "")"
      selected.removeAll()
      releasing = false
    }
  }
}
