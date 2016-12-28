//  Created by Michael Kirk on 12/23/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation
import UserNotifications

enum NotificationsAdapterCategory: String {
    case incomingCall, missed
}

enum NotificationsAdapterCallActions: String {
    case answer, decline, callBack
}

let kNotificationsAdapterCallCategory = "NotificationsAdapterCallCategory"

@available(iOS 10.0, *)
class UserNotificationsAdaptee: NSObject, OWSCallNotificationsAdaptee {

    let TAG = "[UserNotificationsAdaptee]"

    private let center = UNUserNotificationCenter.current()

    public func presentIncomingCall(fromSignalId signalId: String!, callerName: String!) {
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

//@objc(OWSLocalNotificationsAdaptee)
//class LocalNotificationsAdaptee: NSObject, CallNotificationsAdaptee {
//    let TAG = "[LocalNotificationsAdaptee]"
//
//    private let preferences: PropertyListPreferences
//    private let contactsManager: OWSContactsManager
//
//    required init(contactsManager: OWSContactsManager, preferences: PropertyListPreferences) {
//        self.contactsManager = contactsManager
//        self.preferences = preferences
//    }
//
//    func handleAction(_ callAction: NotificationsAdapterCallActions) {
////        switch callAction {
////        case .answerCall:
////
////        case .rejectCall:
////        case .callBack:
////        }
//    }
//
//    var incomingCallCategory: UIUserNotificationCategory {
//        let answerAction = UIMutableUserNotificationAction()
//        answerAction.identifier = NotificationsAdapterCallActions.answer.rawValue
//        answerAction.title = NSLocalizedString("ANSWER_CALL_BUTTON_TITLE", comment:"notification action button")
//        answerAction.activationMode = .foreground
//        answerAction.isDestructive = false
//        answerAction.isAuthenticationRequired = true
//
//        let declineAction = UIMutableUserNotificationAction()
//        declineAction.identifier = NotificationsAdapterCallActions.decline.rawValue
//        declineAction.title = NSLocalizedString("REJECT_CALL_BUTTON_TITLE", comment:"notification action button")
//        declineAction.activationMode = .background
//        declineAction.isDestructive = false
//        declineAction.isAuthenticationRequired = true
//
//        let callCategory = UIMutableUserNotificationCategory()
//        callCategory.identifier = NotificationsAdapterCategory.incomingCall.rawValue
//        callCategory.setActions([answerAction, declineAction], for:.minimal)
//        callCategory.setActions([answerAction, declineAction], for:.default)
//
//        return callCategory
//    }
//
//    func presentIncomingCall(fromSignalId signalId: String) {
//        Logger.debug("\(TAG) \(#function)")
//        let notification = UILocalNotification()
//
//        let callerName = contactsManager.displayName(forPhoneIdentifier: signalId)
//
//        let alertBody = { () -> String in
//            switch preferences.notificationPreviewType() {
//            case .noNameNoPreview:
//                return NSLocalizedString("INCOMING_CALL", comment: "Lock Screen notification body")
//            case .nameNoPreview, .namePreview:
//                let format = NSLocalizedString("INCOMING_CALL_FROM", comment: "Lock Screen notification body. Embeds {{caller name}}")
//                return String(format: format, callerName)
//        }}()
//        notification.alertBody = "☎️ \(alertBody)"
//
//        notification.category = NotificationsAdapterCategory.incomingCall.rawValue
//        notification.soundName = "r.caf"
//
//        present(notification: notification)
//    }
//
//    func missedCall(_ call: SignalCall) {
//        Logger.debug("\(TAG) \(#function)")
//        let notification = UILocalNotification()
//
//
//        //            // Remove previous notification of call and show missed notification.
//        //            UILocalNotification *notif = [[PushManager sharedManager] closeVOIPBackgroundTask];
//        //            TSContactThread *cThread   = (TSContactThread *)thread;
//        //
//        //            if (call.callType == RPRecentCallTypeMissed) {
//        //                if (notif) {
//        //                    [[UIApplication sharedApplication] cancelLocalNotification:notif];
//        //                }
//        //
//        //                UILocalNotification *notification = [[UILocalNotification alloc] init];
//        //                notification.soundName            = @"NewMessage.aifc";
//        //                if ([[Environment preferences] notificationPreviewType] == NotificationNoNameNoPreview) {
//        //                    notification.alertBody = [NSString stringWithFormat:NSLocalizedString(@"MISSED_CALL", nil)];
//        //                } else {
//        //                    notification.userInfo = @{Signal_RPCall_UserInfo_Key : cThread.contactIdentifier};
//        //                    notification.category = Signal_CallBack_Category;
//        //                    notification.alertBody =
//        //                        [NSString stringWithFormat:NSLocalizedString(@"MSGVIEW_MISSED_CALL", nil), [thread name]];
//        //                }
//        //                
//        //                [[PushManager sharedManager] presentNotification:notification];
//        //            }
//        //        }
//    }
//
//    private func present(notification: UILocalNotification) {
//        Logger.debug("\(TAG) presenting notification with category: \(notification.category)")
//        UIApplication.shared.presentLocalNotificationNow(notification)
//    }
//}


