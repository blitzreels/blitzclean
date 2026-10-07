import Testing

@testable import BlitzClean

struct PermissionSkipTests {
  @Test func skippedPermissionsLeaveTheBadgeButStayMissing() {
    let skipped = PermissionSkips.decode(PermissionSkips.encode([.notifications]))
    let state = PermissionState(
      notifications: false, accessibility: true, fullDiskAccess: false, skipped: skipped)
    #expect(state.missing == [.notifications, .fullDiskAccess])
    #expect(state.pending == [.fullDiskAccess])
    #expect(state.skippedMissing == [.notifications])
    #expect(state.missingCount == 1)
  }

  @Test func grantedPermissionIsNeverReportedAsSkipped() {
    let state = PermissionState(
      notifications: true, accessibility: true, fullDiskAccess: true, skipped: [.notifications])
    #expect(state.skippedMissing.isEmpty)
    #expect(state.missingCount == 0)
    #expect(PermissionSkips.decode("bogus,accessibility") == [.accessibility])
  }
}
