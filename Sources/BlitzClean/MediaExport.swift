import Darwin
import Foundation

enum MediaExportKind: String, CaseIterable, Identifiable, Sendable {
  case video = "Compressed MP4"
  case image = "JPEG"
  case losslessImage = "Lossless PNG"
  case join = "Join videos"
  var id: Self { self }
  var detail: String {
    switch self {
    case .video:
      "Balanced quality, original resolution, main video and audio."
    case .image:
      "High-quality JPEG. Transparency and animation are not supported."
    case .losslessImage:
      "Lossless PNG encoding. File size can increase."
    case .join:
      "Join matching video formats in the order below without re-encoding."
    }
  }
}

struct MediaExportRequest: Sendable {
  let files: [ReviewFile]
  let roots: [String]
  let destination: URL
  let kind: MediaExportKind
}

struct MediaExportResult: Codable, Identifiable, Sendable {
  let id: UUID
  let date: Date
  let kind: String
  let sources: [String]
  let output: String
  let inputBytes: Int64
  let outputBytes: Int64
}

struct MediaOperationError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

struct MediaProbe: Decodable, Sendable {
  struct Stream: Decodable, Equatable, Sendable {
    let codecName: String?
    let codecType: String?
    let width: Int?
    let height: Int?
    let pixFmt: String?
    let timeBase: String?
    let rFrameRate: String?
    let sampleRate: String?
    let channels: Int?
    let channelLayout: String?
    let extradataHash: String?
    let colorTransfer: String?
    let nbFrames: String?

    var signature: [String] {
      [
        codecName ?? "", codecType ?? "", String(width ?? 0), String(height ?? 0), pixFmt ?? "",
        timeBase ?? "", rFrameRate ?? "", sampleRate ?? "", String(channels ?? 0),
        channelLayout ?? "", extradataHash ?? "", colorTransfer ?? "",
      ]
    }
  }
  struct Format: Decodable, Sendable {
    let duration: String?
  }
  let streams: [Stream]
  let format: Format
  var duration: Double? { format.duration.flatMap(Double.init) }
  var video: Stream? { streams.first { $0.codecType == "video" } }
  var audioCount: Int { streams.filter { $0.codecType == "audio" }.count }
}

enum MediaExportEngine {
  static func executable(_ name: String) -> String? {
    ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"].map { $0 + name }
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  static func probe(_ url: URL) throws -> MediaProbe {
    guard let executable = executable("ffprobe") else {
      throw MediaOperationError(
        message: "FFprobe is not installed. Install FFmpeg with Homebrew to use media exports.")
    }
    let data = try MediaProcess.run(
      .init(
        executable: executable,
        arguments: [
          "-v", "error", "-protocol_whitelist", "file,pipe", "-show_streams", "-show_format",
          "-show_data_hash", "sha256", "-print_format", "json", url.path,
        ],
        directory: url.deletingLastPathComponent(), timeout: 20, diskGuard: nil))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(MediaProbe.self, from: data)
  }

  static func run(_ request: MediaExportRequest) throws -> MediaExportResult {
    guard let ffmpeg = executable("ffmpeg"), !request.files.isEmpty else {
      throw MediaOperationError(message: "FFmpeg is not installed, or no files were selected.")
    }
    guard request.files.count <= 20, request.kind == .join || request.files.count == 1,
      request.kind != .join || request.files.count >= 2
    else {
      throw MediaOperationError(message: "Choose one file to optimize, or 2–20 videos to join.")
    }
    for file in request.files {
      try ReviewFileDeletion.validateIdentity(.init(file: file, roots: request.roots))
      let activity = CleanupActivity.command(["-nP", "-Fpc", "--", file.path])
      guard activity.status == 1, activity.output.isEmpty else {
        throw MediaOperationError(message: "Close \(file.name) in other apps before exporting it.")
      }
    }
    let destination = request.destination.resolvingSymlinksInPath()
    let inputBytes = request.files.reduce(Int64(0)) { $0 + max(0, $1.logicalBytes) }
    guard let capacity = CleanupVolume.read(destination.path),
      capacity.available > UInt64(inputBytes) + 128 * 1_024 * 1_024
    else {
      throw MediaOperationError(
        message: "Choose a destination with at least the selected files' size plus 128 MB free.")
    }
    let staging = destination.appendingPathComponent(".blitzclean-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: staging) }
    let probes = try request.files.map { try probe(URL(fileURLWithPath: $0.path)) }
    let ext = try outputExtension(.init(request: request, probes: probes))
    let output = staging.appendingPathComponent("output.\(ext)")
    let arguments = try arguments(.init(request: request, staging: staging, output: output))
    _ = try MediaProcess.run(
      .init(
        executable: ffmpeg, arguments: arguments,
        directory: staging, timeout: 7_200, diskGuard: destination))
    for file in request.files {
      try ReviewFileDeletion.validateIdentity(.init(file: file, roots: request.roots))
    }
    let result = try probe(output)
    guard let video = result.video, (video.width ?? 0) > 0, (video.height ?? 0) > 0 else {
      throw MediaOperationError(
        message: "The exported file has no readable picture. Originals are intact.")
    }
    if request.kind == .video || request.kind == .join {
      let expected = probes.compactMap(\.duration).reduce(0, +)
      guard expected > 0, let duration = result.duration,
        abs(duration - expected) <= max(0.5, expected * 0.01),
        result.audioCount == probes[0].audioCount
      else {
        throw MediaOperationError(
          message: "The output duration or audio did not match. Originals are intact.")
      }
    }
    _ = try MediaProcess.run(
      .init(
        executable: ffmpeg,
        arguments: [
          "-v", "error", "-xerror", "-nostdin", "-threads", "2", "-protocol_whitelist", "file,pipe",
          "-i", output.path, "-map", "0:v?", "-map", "0:a?", "-f", "null", "-",
        ],
        directory: staging, timeout: 7_200, diskGuard: destination))
    try Task.checkCancellation()
    for file in request.files {
      try ReviewFileDeletion.validateIdentity(.init(file: file, roots: request.roots))
    }
    let final = destination.appendingPathComponent(
      "BlitzClean-\(UUID().uuidString.prefix(8)).\(ext)")
    try FileManager.default.moveItem(at: output, to: final)
    let size =
      (try FileManager.default.attributesOfItem(atPath: final.path)[.size] as? NSNumber)?.int64Value
      ?? 0
    return .init(
      id: UUID(), date: .now, kind: request.kind.rawValue, sources: request.files.map(\.path),
      output: final.path, inputBytes: inputBytes, outputBytes: size)
  }

  struct Validation {
    let request: MediaExportRequest
    let probes: [MediaProbe]
  }

  static func outputExtension(_ input: Validation) throws -> String {
    let request = input.request
    guard let first = input.probes.first, let video = first.video else {
      throw MediaOperationError(
        message: "The selected file has no supported video or image stream.")
    }
    switch request.kind {
    case .join:
      guard request.files.allSatisfy({ $0.kind == "Video" }),
        input.probes.allSatisfy({ $0.streams.map(\.signature) == first.streams.map(\.signature) })
      else {
        throw MediaOperationError(
          message: "Joining requires matching codecs, resolution, frame rate, and audio tracks.")
      }
      let ext = URL(fileURLWithPath: request.files[0].path).pathExtension.lowercased()
      guard ["mp4", "mov", "mkv", "m4v", "webm"].contains(ext) else {
        throw MediaOperationError(message: "This container is not supported for joining.")
      }
      return ext
    case .video:
      guard request.files[0].kind == "Video",
        !["smpte2084", "arib-std-b67"].contains(video.colorTransfer ?? "")
      else {
        throw MediaOperationError(
          message: "Choose a standard dynamic range video. HDR originals need a color-aware export."
        )
      }
      return "mp4"
    case .image, .losslessImage:
      guard request.files[0].kind == "Image", video.codecName != "apng",
        (Int(video.nbFrames ?? "1") ?? 1) <= 1,
        !["gif", "webp"].contains(
          URL(fileURLWithPath: request.files[0].path).pathExtension.lowercased())
      else {
        throw MediaOperationError(
          message: "Choose a still image. Animated images are not flattened.")
      }
      if request.kind == .image, let format = video.pixFmt,
        format.contains("rgba") || format.contains("bgra") || format.contains("yuva")
          || format.contains("gbrap") || format == "pal8" || format.hasPrefix("ya")
      {
        throw MediaOperationError(
          message: "This image may contain transparency. Choose Lossless PNG to preserve it.")
      }
      return request.kind == .image ? "jpg" : "png"
    }
  }

  struct Arguments {
    let request: MediaExportRequest
    let staging: URL
    let output: URL
  }

  static func arguments(_ input: Arguments) throws -> [String] {
    let request = input.request
    var args = [
      "-hide_banner", "-v", "error", "-nostdin", "-n", "-threads", "2", "-filter_threads", "2",
    ]
    if request.kind == .join {
      var manifest = "ffconcat version 1.0\n"
      for (index, file) in request.files.enumerated() {
        let name = "clip-\(index).media"
        try FileManager.default.createSymbolicLink(
          atPath: input.staging.appendingPathComponent(name).path,
          withDestinationPath: file.path)
        manifest += "file '\(name)'\n"
      }
      let list = input.staging.appendingPathComponent("clips.ffconcat")
      try manifest.write(to: list, atomically: true, encoding: .utf8)
      args += [
        "-protocol_whitelist", "file,pipe", "-f", "concat", "-safe", "1", "-i", list.path,
        "-map", "0", "-c", "copy",
      ]
    } else {
      args += [
        "-protocol_whitelist", "file,pipe", "-noautorotate", "-i", request.files[0].path,
        "-map_metadata", "0", "-map", "0:v:0",
      ]
      switch request.kind {
      case .video:
        args += [
          "-map", "0:a?", "-c:v", "libx264", "-preset", "medium", "-crf", "23",
          "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-pix_fmt", "yuv420p", "-threads", "2",
          "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
        ]
      case .image:
        args += ["-frames:v", "1", "-c:v", "mjpeg", "-q:v", "2", "-update", "1"]
      case .losslessImage:
        args += [
          "-frames:v", "1", "-c:v", "png", "-compression_level", "9", "-pred", "mixed", "-update",
          "1",
        ]
      case .join: break
      }
    }
    return args + [input.output.path]
  }
}
