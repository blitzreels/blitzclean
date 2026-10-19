import Foundation
import Testing

@testable import BlitzClean

struct DockIconPreferenceTests {
  private func defaults() -> UserDefaults {
    let suite = "DockIconPreferenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  @Test func unsetShowsDockIcon() {
    #expect(DockIconPreference.policy(defaults()) == .regular)
  }

  @Test func savedChoiceIsHonored() {
    let defaults = defaults()
    defaults.set(false, forKey: DockIconPreference.key)
    #expect(DockIconPreference.policy(defaults) == .accessory)
    defaults.set(true, forKey: DockIconPreference.key)
    #expect(DockIconPreference.policy(defaults) == .regular)
  }
}
