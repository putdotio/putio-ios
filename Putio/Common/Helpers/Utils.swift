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
