import SwiftUI

struct BackgroundLoadSection: View {
  @ObservedObject var model: BackgroundLoadModel
  let resources: [ResourceProcess]
  let onConfirm: (PendingProcessAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      BlitzSectionHeader(title: "Background load", count: model.findings.count) {
        Text("Runs without anyone starting it").font(BlitzType.caption)
          .foregroundStyle(BlitzUI.tertiaryText)
      }
      if let message = model.message {
        Text(message).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }
      VStack(spacing: 0) {
        if model.findings.isEmpty {
          BlitzEmptyRow(
            text: model.scannedAt == nil
              ? "Checking what runs in the background…" : "Nothing found",
            isLoading: model.scannedAt == nil)
        }
        ForEach(model.findings) { finding in
          row(finding)
          if finding.id != model.findings.last?.id { BlitzRowDivider(leading: 56) }
        }
      }.blitzTable()
    }
    .task(id: resources.count) { model.scan(resources) }
  }

  private func row(_ finding: BackgroundFinding) -> some View {
    HStack(spacing: 12) {
      BlitzIconTile(
        symbol: finding.kind.symbol,
        tone: finding.kind == .failingJob || finding.kind == .memoryCleaner ? .warning : .muted,
        size: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(finding.title).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
        Text(finding.detail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle)
      }.frame(maxWidth: .infinity, alignment: .leading)
        .help("\(finding.title)\n\(finding.detail)")
      BlitzTrailingValue(value: finding.value ?? "", detail: nil)
        .frame(width: 80, alignment: .trailing)
      button(finding).frame(width: 96, alignment: .trailing)
    }.blitzRow()
  }

  @ViewBuilder private func button(_ finding: BackgroundFinding) -> some View {
    switch finding.action {
    case .turnOff(let service):
      Button {
        onConfirm(
          .init(
            title: "Turn off \(service.command)?",
            message:
              "\(service.command) · \(finding.value ?? "login service")\n\n"
              + "It stops now and no longer starts at login. Its file moves to LaunchAgents/"
              + "\(BackgroundLoadActions.disabledFolder), so moving it back turns it on again.",
            confirmTitle: "Turn Off",
            perform: { perform(finding) }))
      } label: {
        BlitzActionLabel(title: "Turn Off")
      }.blitzButton(.secondary).controlSize(.small)
    case .quit:
      Button {
        perform(finding)
      } label: {
        BlitzActionLabel(title: "Quit")
      }.blitzButton(.secondary).controlSize(.small)
    case .reveal:
      Button("Show Report") { perform(finding) }
        .blitzButton(.quiet).controlSize(.small)
    case nil:
      EmptyView()
    }
  }

  private func perform(_ finding: BackgroundFinding) {
    guard let action = finding.action else { return }
    model.perform(.init(action: action, title: finding.title, resources: resources))
  }
}
