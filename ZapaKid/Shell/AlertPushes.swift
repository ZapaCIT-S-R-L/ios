import Foundation
import os
import UIKit
import UserNotifications
import ZapaKidKit

/// Chat notifications while the app is closed. Asks for permission (the system only prompts while it is undecided),
/// registers with APNs once allowed, and hands the standard device token on. Calls use the separate PushKit VoIP
/// token (`VoIPPushes`): the two are never mixed.
@MainActor
enum AlertPushes {
    private static let log = Logger(subsystem: "ro.zapakid.app", category: "alert-push")

    /// The APNs token (hex), kept so a sync that starts after APNs answered still gets it.
    private(set) static var token: String?

    /// Receives the token, and again each time APNs issues a new one. Set once by the live services.
    static var onToken: (@MainActor (String) -> Void)? {
        didSet {
            if let token {
                onToken?(token)
            }
        }
    }

    /// Asks for permission if it is undecided, and registers with APNs whenever notifications are allowed. Called each
    /// time the signed-in shell appears, so a token that changed is sent again.
    static func start() async {
        #if DEBUG
            // UI tests run without the permission prompt (`-zk-ui-test`, see UITestStubs).
            if ProcessInfo.processInfo.arguments.contains(UITestStubs.launchArgument) {
                return
            }
        #endif
        let center = UNUserNotificationCenter.current()
        let allowed: Bool
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            allowed = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .authorized, .provisional, .ephemeral:
            allowed = true
        case .denied:
            allowed = false
        @unknown default:
            allowed = false
        }
        if allowed {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// APNs gave this phone its device token (raw bytes).
    static func registered(_ deviceToken: Data) {
        let hex = PushTargetSync.hex(deviceToken)
        token = hex
        onToken?(hex)
    }

    /// APNs refused or failed. Only the error's domain and code are logged, never anything that could identify the phone.
    static func failed(_ error: Error) {
        let nsError = error as NSError
        log.error("APNs registration failed: \(nsError.domain, privacy: .public) \(nsError.code)")
    }
}

/// The app delegate SwiftUI keeps for the app: APNs registration callbacks and how notifications show while the app
/// is open. (The PushKit VoIP setup stays in `LiveServices`.)
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Set at launch, so a notification that opens the app is handled by this delegate too.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AlertPushes.registered(deviceToken)
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AlertPushes.failed(error)
    }

    /// A chat notification that arrives while the app is open shows as a banner with its sound, as it does when the app
    /// is closed. The payload is content-free, so it can't say which chat it is for: hiding it while a chat is open
    /// would also hide the other chats.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
