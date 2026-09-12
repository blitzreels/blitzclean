import AppKit
import SwiftUI

struct WorkspaceSettingsView: View {
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var storage: StorageBreakdownModel
  @State private var roots = DeveloperLocations.additionalProjectRoots
  @State private var volume = DeveloperLocations.volumePath

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("Your Mac. Your preferences.").font(.title.bold())
        MemoryGuardControls(model: memory)
        VStack(alignment: .leading, spacing: 14) {
          Text("Additional project folders").font(.headline)
          Text(
            "Your home development folders are scanned by default. Add external projects only when you want them included."
          )
          .foregroundStyle(.secondary)
          ForEach(roots, id: \.self) { root in
            HStack {
              Text(root).lineLimit(1).truncationMode(.middle)
              Spacer()
              Button("Remove") {
                roots.removeAll { $0 == root }
                UserDefaults.standard.set(roots, forKey: "locations.projectRoots")
              }
            }
          }
          HStack {
            Button("Add folder") {
              if let path = chooseFolder(), !roots.contains(path) {
                roots.append(path)
                UserDefaults.standard.set(roots, forKey: "locations.projectRoots")
              }
            }
            Button("Refresh storage") { storage.scan() }.disabled(storage.isScanning)
          }
        }.panelCard(padding: 20)
        VStack(alignment: .leading, spacing: 14) {
          Text("Developer volume").font(.headline)
          Text(volume ?? "No additional volume selected").foregroundStyle(.secondary)
          HStack {
            Button("Choose volume") {
              if let selected = chooseFolder() {
                volume = selected
                UserDefaults.standard.set(selected, forKey: "locations.developerVolume")
              }
            }
            if volume != nil {
              Button("Clear") {
                volume = nil
                UserDefaults.standard.removeObject(forKey: "locations.developerVolume")
              }
            }
          }
          Text("Shows its available capacity. This does not add it to cleanup scans.")
            .font(.caption).foregroundStyle(.secondary)
        }.panelCard(padding: 20)
      }.padding(28)
    }.navigationTitle("Settings")
  }

  private func chooseFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK else { return nil }
    return panel.url?.path
  }
}
