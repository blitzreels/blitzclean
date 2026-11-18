import SwiftUI

struct DriveCleanupReviewView: View {
  let drive: StorageDrive
  let report: DriveContentsReport
  let history: CleanupOverviewModel
  let browse: (String) -> Void
  let refresh: () -> Void
  @State private var kept: [String] = []
  @State private var comparison: MediaDuplicateResult?
  @State private var comparing = false
  @State private var pending: DriveDuplicateReview?
  @State private var moving = false
  @State private var status: String?

  private var protection: DriveKeptFolders { .init(drive: drive) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let status { BlitzStatusLine(text: status, tone: .working) }
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Exact duplicates").font(BlitzType.title)
          Spacer()
          Button(comparing ? "Stop comparison" : "Compare largest files") {
            comparing.toggle()
          }.blitzButton(.secondary).disabled(moving || pending != nil)
        }
        Text("Compares the contents of up to \(DriveContents.fileLimit) large files per category.")
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        if comparing { BlitzProgressBar(fraction: nil, height: 3) }
        if let comparison {
          Text(
            "\(comparison.groups.count) matching groups · \(comparison.skipped) skipped"
              + (comparison.limited ? " · comparison incomplete" : "")
          )
          .font(BlitzType.caption)
          ForEach(comparison.groups) { group in
            let files = group.files.sorted {
              let left = protection.protects($0.path)
              let right = protection.protects($1.path)
              return left == right ? $0.path < $1.path : left
            }
            if let keeper = files.first {
              Text("Keep · " + keeper.path).font(BlitzType.caption).textSelection(.enabled)
              ForEach(files.dropFirst()) { file in
                HStack {
                  Text(file.path).font(BlitzType.body).lineLimit(2).truncationMode(.middle).help(
                    file.path)
                  Spacer()
                  Text(ByteText.capacity(file.bytes)).monospacedDigit()
                  if protection.protects(file.path) {
                    Text("Kept").font(BlitzType.caption)
                  } else {
                    Button("Review copy") {
                      pending = .init(
                        file: file, keeper: keeper, digest: group.digest, drive: drive)
                    }
                    .blitzButton(.secondary).disabled(moving)
                  }
                }
              }
              Divider()
            }
          }
        }
      }.blitzCard(padding: 16)
      if let pending {
        BlitzConfirmation(
          title: "Move this copy to Trash?",
          message: pending.file.path + " · " + ByteText.capacity(pending.file.bytes) + "\n\nKeep "
            + pending.keeper.path + ". Space becomes available when the Trash is emptied.",
          confirmTitle: "Move to Trash", onConfirm: { move(pending) },
          onCancel: { self.pending = nil })
      }
      let builds = report.contents.buildFolders.filter { !protection.protects($0.key) }.sorted {
        $0.value > $1.value
      }
      VStack(alignment: .leading, spacing: 10) {
        Text("Rebuildable folders").font(BlitzType.title)
        if builds.isEmpty { Text("No matching build folders to review.").font(BlitzType.body) }
        ForEach(builds.prefix(20), id: \.key) { folder in
          HStack {
            Text(folder.key).font(BlitzType.body).lineLimit(2).truncationMode(.middle).help(
              folder.key)
            Spacer()
            Text(ByteText.capacity(folder.value)).monospacedDigit()
            Button("Review folder") { browse(folder.key) }
              .blitzButton(.secondary)
          }
        }
      }.blitzCard(padding: 16)
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Keep always").font(BlitzType.title)
          Spacer()
          Button("Choose folder…") {
            guard let path = Finder.chooseFolder() else { return }
            guard let canonical = ReviewFile.canonicalPath(path),
              let relative = protection.relative(canonical),
              let owner = StorageDrives.containing(
                (StorageGuidance.visiblePath(canonical), ConnectedDrivesModel.shared.drives)),
              owner.path == drive.path
            else {
              status = "Choose a folder on " + drive.name + "."
              return
            }
            protection.set(Array(Set(kept + [relative])))
            kept = protection.folders
            pending = nil
            status = nil
          }.blitzButton(.secondary)
        }
        Text("Folders excluded from cleanup on this drive.").font(BlitzType.caption)
          .foregroundStyle(BlitzUI.secondaryText)
        ForEach(kept, id: \.self) { relative in
          HStack {
            Text(relative.isEmpty ? drive.name : relative).font(BlitzType.body)
            Spacer()
            Button("Allow cleanup") {
              protection.set(kept.filter { $0 != relative })
              kept = protection.folders
            }
            .blitzButton(.quiet)
          }
        }
      }.blitzCard(padding: 16).disabled(moving)
    }
    .onAppear { kept = protection.folders }
    .task(id: comparing) {
      guard comparing else { return }
      comparison = nil
      let files = report.contents.largest.values.flatMap { $0 }
      let task = Task.detached(priority: .utility) {
        MediaDuplicateScanner.compare(files.filter { ReviewFileDeletion.canTrashPath($0.path) })
      }
      let result = await withTaskCancellationHandler {
        await task.value
      } onCancel: {
        task.cancel()
      }
      guard !Task.isCancelled else { return }
      comparison = result
      comparing = false
    }
  }

  private func move(_ review: DriveDuplicateReview) {
    pending = nil
    guard !moving else { return }
    moving = true
    Task {
      do {
        try await Task.detached(priority: .utility) { try review.trash() }.value
        history.record(
          .init(
            id: UUID().uuidString, date: .now, title: "Moved duplicate to Trash",
            paths: [review.file.path], before: nil, after: nil, bytes: review.file.bytes))
        comparison = nil
        refresh()
      } catch { status = "Copy kept. " + error.localizedDescription }
      moving = false
    }
  }
}
