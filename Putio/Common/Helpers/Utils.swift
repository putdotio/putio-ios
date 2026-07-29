import UIKit
import Foundation
import UserNotifications
import AVFoundation
import Sentry

class Utils {
    static func delayWithSeconds(_ seconds: Double, completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            completion()
        }
    }

    static func authorizeNotifications(application: UIApplication) {
        // The permission alert is a system window, so it lands on top of
        // whatever a screenshot walk is capturing and no in-app wait can see it
        // coming. On iPhone the capture happened to win that race; on iPad it
        // did not, and slot 1 of the App Store set came out with an alert across
        // it. Nothing mocked needs push, so nothing mocked should ask.
        guard !PutioE2EEnvironment.isMockAPIEnabled else { return }

        let center = UNUserNotificationCenter.current()

        center.getNotificationSettings { (notificationSettings) in
            switch notificationSettings.authorizationStatus {
            case .notDetermined:
                let options: UNAuthorizationOptions = [.alert, .sound, .badge]
                center.requestAuthorization(options: options) { (granted, _)  in
                    guard granted else { return }
                    DispatchQueue.main.async {
                        application.registerForRemoteNotifications()
                    }
                }

            case .authorized:
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }

            case .denied:
                log.warning("Application Not Allowed to Display Notifications")

            case .provisional:
                log.info("Notification auth status is provisional")
            case .ephemeral:
                log.info("Notification auth status is temporal for app clips")
            @unknown default:
                log.warning("Unhandled notification auth status: \(notificationSettings.authorizationStatus.rawValue)")
            }
        }
    }

    static func configureAVSession(
        setCategory: () throws -> Void = { try AVAudioSession.sharedInstance().setCategory(.playback) },
        onFailure: (Error) -> Void = { error in
            log.error("AVAudioSession configuration failed: \(error.localizedDescription)")
        }
    ) {
        do {
            try setCategory()
        } catch {
            onFailure(error)
        }
    }
}
