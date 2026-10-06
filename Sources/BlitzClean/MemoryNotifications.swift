import AppKit
import UserNotifications

extension Notification.Name {
  static let openWorkspace = Notification.Name("BlitzClean.openWorkspace")
  static let openAppRecovery = Notification.Name("BlitzClean.openAppRecovery")
  static let openMemoryRescue = Notification.Name("BlitzClean.openMemoryRescue")
  static let openStorageReview = Notification.Name("BlitzClean.openStorageReview")
}

@MainActor
final class MemoryNotifications: NSObject, UNUserNotificationCenterDelegate {
  private(set) var status = "Checking notification permission"
  private(set) var authorized = false

  private struct PermissionSnapshot: Sendable {
    let notDetermined: Bool
    let authorized: Bool
    let alertsEnabled: Bool
  }

  private func permissionSnapshot() async -> PermissionSnapshot {
    await withCheckedContinuation { continuation in
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        continuation.resume(
          returning: PermissionSnapshot(
            notDetermined: settings.authorizationStatus == .notDetermined,
            authorized: settings.authorizationStatus == .authorized
              || settings.authorizationStatus == .provisional,
            alertsEnabled: settings.alertSetting == .enabled))
      }
    }
  }

  private var isAppBundle: Bool {
    Bundle.main.bundleIdentifier == AppBrand.bundleIdentifier
      && Bundle.main.bundleURL.pathExtension == "app"
  }

  func prepare(requestPermission: Bool) async {
    guard isAppBundle else {
      status = "Notifications require the installed app"
      return
    }
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let action = UNNotificationAction(
      identifier: "review", title: "Review memory", options: .foreground)
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: "memory", actions: [action], intentIdentifiers: [], options: []),
      UNNotificationCategory(
        identifier: "storage",
        actions: [
          UNNotificationAction(
            identifier: "review-storage", title: "Review storage", options: .foreground)
        ],
        intentIdentifiers: [], options: []),
    ])
    var settings = await permissionSnapshot()
    if settings.notDetermined && requestPermission {
      do {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
      } catch {
        status = "Notification request failed: \(error.localizedDescription)"
        return
      }
      settings = await permissionSnapshot()
    }
    authorized = settings.authorized
    if !authorized {
      status = "Allow \(AppBrand.name) in System Settings → Notifications"
    } else if !settings.alertsEnabled {
      status = "Permission granted; enable banners in Notification Settings"
    } else {
      status = "Alerts allowed · Focus and macOS settings still apply"
    }
  }

  struct Alert {
    let risk: MemoryRisk
    let detail: String
    let isTest: Bool
  }

  func send(_ alert: Alert) async -> Bool {
    guard isAppBundle, authorized else { return false }
    let content = UNMutableNotificationContent()
    content.title = alert.isTest ? "Test alert" : alert.risk.title
    content.body = alert.detail
    content.categoryIdentifier = "memory"
    content.sound = .default
    do {
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(
          identifier: alert.isTest ? "memory-guard-test" : "memory-guard", content: content,
          trigger: nil)
      )
      return true
    } catch {
      status = "Notification could not be scheduled: \(error.localizedDescription)"
      return false
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound, .list])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.actionIdentifier != UNNotificationDismissActionIdentifier {
      let name: Notification.Name =
        response.notification.request.content.categoryIdentifier == "storage"
        ? .openStorageReview : .openMemoryRescue
      Task { @MainActor in
        NotificationCenter.default.post(name: name, object: nil)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    completionHandler()
  }

  func sendDisk(_ assessment: DiskAssessment) async -> Bool {
    guard isAppBundle, authorized else { return false }
    let content = UNMutableNotificationContent()
    content.title = assessment.risk.title
    content.body = assessment.detail + ". Review storage and memory before starting another build."
    content.categoryIdentifier = "storage"
    content.sound = .default
    do {
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: "disk-guard", content: content, trigger: nil))
      return true
    } catch {
      status = "Disk notification could not be scheduled: \(error.localizedDescription)"
      return false
    }
  }
}
