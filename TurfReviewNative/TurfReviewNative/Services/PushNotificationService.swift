import Foundation
import OSLog
import UserNotifications

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Notification.Name {
  static let turfReviewNotificationTapped = Notification.Name("turfReviewNotificationTapped")
}

@MainActor
enum PushNotificationTapRouter {
  private static var pendingURL: URL?

  static func publish(_ url: URL) {
    pendingURL = url
    NotificationCenter.default.post(name: .turfReviewNotificationTapped, object: url)
  }

  static func takePendingURL() -> URL? {
    defer { pendingURL = nil }
    return pendingURL
  }

  static func consume(_ url: URL) {
    if pendingURL == url {
      pendingURL = nil
    }
  }
}

struct PushDeviceRegistration: Codable, Equatable {
  let token: String
  let platform: String
  let environment: String
  let bundleId: String
}

private struct PushDeviceRegistrationResponse: Decodable {
  let ok: Bool
  let created: Bool
  let deliveryConfigured: Bool
}

private struct PushDeviceDeactivationResponse: Decodable {
  let ok: Bool
  let deactivated: Bool
}

actor PushNotificationService {
  static let shared = PushNotificationService()

  private static let storedRegistrationKey = "turf.pushRegistration"
  private let logger = Logger(subsystem: "com.jamesheffernan.turfreview", category: "push")
  private let session: URLSession
  private let defaults: UserDefaults

  init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
    self.session = session
    self.defaults = defaults
  }

  func register(deviceToken: Data) async {
    guard let registration = Self.registration(deviceToken: deviceToken) else {
      logger.error("Remote notification registration is missing a bundle identifier")
      return
    }

    if let previous = storedRegistration(), previous != registration {
      do {
        try await mutate(previous, method: "DELETE")
        removeStoredRegistration()
      } catch {
        logger.error("Could not retire the previous push token: \(error.localizedDescription, privacy: .public)")
      }
    }

    do {
      try await mutate(registration, method: "POST")
      store(registration)
    } catch {
      logger.error("Could not register for Turf Review push notifications: \(error.localizedDescription, privacy: .public)")
    }
  }

  func unregisterStoredDevice() async {
    guard let registration = storedRegistration() else { return }
    do {
      try await mutate(registration, method: "DELETE")
      removeStoredRegistration()
    } catch {
      logger.error("Could not unregister Turf Review push notifications: \(error.localizedDescription, privacy: .public)")
    }
  }

  nonisolated static func reviewURL(from userInfo: [AnyHashable: Any]) -> URL? {
    if let rawURL = userInfo["reviewURL"] as? String,
       let url = URL(string: rawURL) {
      return url
    }

    guard let slug = userInfo["slug"] as? String,
          !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let baseURL = APIConfiguration.load().url(appending: "/review/\(encodedSlug)") else {
      return nil
    }
    return baseURL
  }

  private static func registration(deviceToken: Data) -> PushDeviceRegistration? {
    guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    #if os(iOS)
    let platform = "ios"
    #else
    let platform = "macos"
    #endif
    #if DEBUG
    let environment = "development"
    #else
    let environment = "production"
    #endif
    return PushDeviceRegistration(
      token: token,
      platform: platform,
      environment: environment,
      bundleId: bundleId
    )
  }

  private func mutate(_ registration: PushDeviceRegistration, method: String) async throws {
    let client = TurfReviewClient(configuration: APIConfiguration.load(), session: session)
    switch method {
    case "POST":
      let result: PushDeviceRegistrationResponse = try await client.sendHostedMutation(
        path: "/api/push/devices",
        method: method,
        body: registration
      )
      guard result.ok else { throw PushNotificationError.rejected }
      if !result.deliveryConfigured {
        logger.warning("Push token registered, but server delivery is not configured")
      }
    case "DELETE":
      let result: PushDeviceDeactivationResponse = try await client.sendHostedMutation(
        path: "/api/push/devices",
        method: method,
        body: registration
      )
      guard result.ok else { throw PushNotificationError.rejected }
    default:
      throw PushNotificationError.unsupportedMethod(method)
    }
  }

  private func storedRegistration() -> PushDeviceRegistration? {
    guard let data = defaults.data(forKey: Self.storedRegistrationKey) else { return nil }
    return try? JSONDecoder().decode(PushDeviceRegistration.self, from: data)
  }

  private func store(_ registration: PushDeviceRegistration) {
    guard let data = try? JSONEncoder().encode(registration) else { return }
    defaults.set(data, forKey: Self.storedRegistrationKey)
  }

  private func removeStoredRegistration() {
    defaults.removeObject(forKey: Self.storedRegistrationKey)
  }
}

enum PushNotificationError: LocalizedError {
  case rejected
  case unsupportedMethod(String)

  var errorDescription: String? {
    switch self {
    case .rejected:
      return "The push registration server rejected the request."
    case .unsupportedMethod(let method):
      return "Push registration does not support \(method)."
    }
  }
}

final class PushNotificationAppDelegate: NSObject, UNUserNotificationCenterDelegate {
  private let logger = Logger(subsystem: "com.jamesheffernan.turfreview", category: "push")

  @MainActor
  private func configureNotifications() async {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    var settings = await center.notificationSettings()

    if settings.authorizationStatus == .notDetermined {
      do {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        settings = await center.notificationSettings()
      } catch {
        logger.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
        return
      }
    }

    switch settings.authorizationStatus {
    case .authorized, .provisional:
      registerForRemoteNotifications()
    #if os(iOS)
    case .ephemeral:
      registerForRemoteNotifications()
    #endif
    case .denied:
      unregisterForRemoteNotifications()
      await PushNotificationService.shared.unregisterStoredDevice()
    case .notDetermined:
      break
    @unknown default:
      break
    }
  }

  @MainActor
  private func registerForRemoteNotifications() {
    #if os(iOS)
    UIApplication.shared.registerForRemoteNotifications()
    #elseif os(macOS)
    NSApplication.shared.registerForRemoteNotifications()
    #endif
  }

  @MainActor
  private func unregisterForRemoteNotifications() {
    #if os(iOS)
    UIApplication.shared.unregisterForRemoteNotifications()
    #elseif os(macOS)
    NSApplication.shared.unregisterForRemoteNotifications()
    #endif
  }

  private func didRegister(deviceToken: Data) {
    Task {
      await PushNotificationService.shared.register(deviceToken: deviceToken)
    }
  }

  private func didFailToRegister(_ error: Error) {
    logger.error("APNs device registration failed: \(error.localizedDescription, privacy: .public)")
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    defer { completionHandler() }
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
          let url = PushNotificationService.reviewURL(
            from: response.notification.request.content.userInfo
          ) else {
      return
    }
    Task { @MainActor in
      PushNotificationTapRouter.publish(url)
    }
  }
}

#if os(iOS)
extension PushNotificationAppDelegate: UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    Task { @MainActor in await configureNotifications() }
    return true
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    didRegister(deviceToken: deviceToken)
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    didFailToRegister(error)
  }
}
#elseif os(macOS)
extension PushNotificationAppDelegate: NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in await configureNotifications() }
  }

  func application(
    _ application: NSApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    didRegister(deviceToken: deviceToken)
  }

  func application(
    _ application: NSApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    didFailToRegister(error)
  }
}
#endif
