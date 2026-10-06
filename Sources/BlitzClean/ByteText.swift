import Foundation

enum ByteText {
  static func compact(_ bytes: UInt64) -> String {
    format((bytes: bytes, fractionDigits: 0))
  }

  static func full(_ bytes: UInt64) -> String {
    format((bytes: bytes, fractionDigits: 1))
  }

  private static func format(_ input: (bytes: UInt64, fractionDigits: Int)) -> String {
    let gigabytes = Double(input.bytes) / 1_000_000_000

    if gigabytes >= 1 {
      return gigabytes.formatted(
        .number.precision(.fractionLength(input.fractionDigits))
      ) + " GB"
    }

    if input.bytes < 1_000 { return "\(input.bytes) B" }
    if input.bytes < 1_000_000 {
      return (Double(input.bytes) / 1_000).formatted(
        .number.precision(.fractionLength(input.fractionDigits))
      ) + " KB"
    }
    let megabytes = Double(input.bytes) / 1_000_000
    return megabytes.formatted(
      .number.precision(.fractionLength(input.fractionDigits))
    ) + " MB"
  }
}
