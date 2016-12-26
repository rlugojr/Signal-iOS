//
//  NotificationsAdaptee.swift
//  Signal

import Foundation
import UserNotifications

enum NotificationsAdapterCategory: String {
    case incomingCall, missed
}

@objc(OWSNotificationsAdaptee)
protocol NotificationsAdaptee {
    func incomingCall(fromSignalId signalId: String)
    func missedCall(_ call: SignalCall)
}

@available(iOS 10.0, *)
@objc(OWSUserNotificationsAdaptee)
class UserNotificationsAdaptee: NSObject, NotificationsAdaptee {
    let TAG = "[UserNotificationsAdaptee]"

    private let center = UNUserNotificationCenter.current()

    func incomingCall(fromSignalId signalId: String) {
        Logger.debug("\(TAG) \(#function) is no-op, because it's handled with callkit.")
    }

    func missedCall(_ call: SignalCall) {
        Logger.debug("\(TAG) \(#function)")

        let content = UNMutableNotificationContent()
        content.title = NSString.localizedUserNotificationString(forKey: "Missed Call", arguments: nil)
        content.body = NSString.localizedUserNotificationString(forKey: "from some body.", arguments: nil)
        content.sound = UNNotificationSound.default()
        content.categoryIdentifier = "org.whispersystems.signal.missedCall"
        let request = UNNotificationRequest.init(identifier: "FiveSecond", content: content, trigger: nil)

        center.add(request)
    }
}

@objc(OWSLocalNotificationsAdaptee)
class LocalNotificationsAdaptee: NSObject, NotificationsAdaptee {
    let TAG = "[LocalNotificationsAdaptee]"

    private let preferences: PropertyListPreferences
    private let contactsManager: OWSContactsManager

    required init(contactsManager: OWSContactsManager, preferences: PropertyListPreferences) {
        self.contactsManager = contactsManager
        self.preferences = preferences
    }

    func incomingCall(fromSignalId signalId: String) {
        Logger.debug("\(TAG) \(#function)")
        let notification = UILocalNotification()

        let callerName = contactsManager.displayName(forPhoneIdentifier: signalId)

        let alertBody = { () -> String in
            switch preferences.notificationPreviewType() {
            case .noNameNoPreview:
                return NSLocalizedString("INCOMING_CALL", comment: "Lock Screen notification body")
            case .nameNoPreview, .namePreview:
                let format = NSLocalizedString("INCOMING_CALL_FROM", comment: "Lock Screen notification body. Embeds {{caller name}}")
                return String(format: format, callerName)
        }}()
        notification.alertBody = "☎️ \(alertBody)"

        notification.category = NotificationsAdapterCategory.incomingCall.rawValue
        notification.soundName = "r.caf"

        present(notification: notification)
    }

    func missedCall(_ call: SignalCall) {
        Logger.debug("\(TAG) \(#function)")
        let notification = UILocalNotification()


        //            // Remove previous notification of call and show missed notification.
        //            UILocalNotification *notif = [[PushManager sharedManager] closeVOIPBackgroundTask];
        //            TSContactThread *cThread   = (TSContactThread *)thread;
        //
        //            if (call.callType == RPRecentCallTypeMissed) {
        //                if (notif) {
        //                    [[UIApplication sharedApplication] cancelLocalNotification:notif];
        //                }
        //
        //                UILocalNotification *notification = [[UILocalNotification alloc] init];
        //                notification.soundName            = @"NewMessage.aifc";
        //                if ([[Environment preferences] notificationPreviewType] == NotificationNoNameNoPreview) {
        //                    notification.alertBody = [NSString stringWithFormat:NSLocalizedString(@"MISSED_CALL", nil)];
        //                } else {
        //                    notification.userInfo = @{Signal_Call_UserInfo_Key : cThread.contactIdentifier};
        //                    notification.category = Signal_CallBack_Category;
        //                    notification.alertBody =
        //                        [NSString stringWithFormat:NSLocalizedString(@"MSGVIEW_MISSED_CALL", nil), [thread name]];
        //                }
        //                
        //                [[PushManager sharedManager] presentNotification:notification];
        //            }
        //        }
    }

    private func present(notification: UILocalNotification) {
        Logger.debug("\(TAG) presenting notification with category: \(notification.category)")
        UIApplication.shared.presentLocalNotificationNow(notification)
    }
}
