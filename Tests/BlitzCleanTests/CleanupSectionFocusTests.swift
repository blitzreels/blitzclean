import Testing

@testable import BlitzClean

struct CleanupSectionFocusTests {
  @Test func routesOpenTheirCleanupSections() {
    #expect(StorageCleanupFocus.oldFiles.sectionTitles == ["Old downloads and screenshots"])
    #expect(StorageCleanupFocus.largeFiles.sectionTitles == ["Large personal files"])
    #expect(StorageCleanupFocus.caches.sectionTitles == ["System Data cleanup"])
    #expect(StorageCleanupFocus.simulators.sectionTitles == ["Simulated devices"])
    #expect(StorageCleanupFocus.regrown.sectionTitles == ["Removed before"])
    #expect(StorageCleanupFocus.projects.sectionTitles.contains("Dependencies"))
    #expect(StorageCleanupFocus.docker.sectionTitles == ["Docker"])
  }
}
