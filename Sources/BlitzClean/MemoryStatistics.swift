import Darwin
import Foundation

struct VMMemoryStats: Equatable, Sendable {
  let free: UInt64
  let active: UInt64
  let inactive: UInt64
  let wired: UInt64
  let compressed: UInt64
  let fileBacked: UInt64
  let purgeable: UInt64
  let swapOutBytes: UInt64
  let total: UInt64

  var available: UInt64 {
    min(total, free + fileBacked + purgeable)
  }
}

enum VMMemoryStatsReader {
  static func current() -> VMMemoryStats? {
    var statistics = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
    )
    let result = withUnsafeMutablePointer(to: &statistics) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
        host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
      }
    }

    guard result == KERN_SUCCESS else {
      return nil
    }

    var hostPageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &hostPageSize) == KERN_SUCCESS else {
      return nil
    }

    let pageSize = UInt64(hostPageSize)
    return VMMemoryStats(
      free: (UInt64(statistics.free_count) + UInt64(statistics.speculative_count)) * pageSize,
      active: UInt64(statistics.active_count) * pageSize,
      inactive: UInt64(statistics.inactive_count) * pageSize,
      wired: UInt64(statistics.wire_count) * pageSize,
      compressed: UInt64(statistics.compressor_page_count) * pageSize,
      fileBacked: UInt64(statistics.external_page_count) * pageSize,
      purgeable: UInt64(statistics.purgeable_count) * pageSize,
      swapOutBytes: statistics.swapouts * pageSize,
      total: ProcessInfo.processInfo.physicalMemory
    )
  }
}
