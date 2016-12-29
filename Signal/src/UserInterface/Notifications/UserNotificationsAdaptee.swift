//  Created by Michael Kirk on 12/23/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation
import UserNotifications

@available(iOS 10.0, *)
struct AppNotifications {
    enum Category {
        case missedCall

        // Don't forget to update this! We use it to register categories.
        static let allValues = [ missedCall ]
    }

    enum Action {
        case callBack
    }

    static var allCategories: Set<UNNotificationCategory> {
        let categories = Category.allValues.map { category($0) }
        return Set(categories)
    }

    static func category(_ type: Category) -> UNNotificationCategory {
        switch type {
        case .missedCall:
            return UNNotificationCategory(identifier: "org.whispersystems.signal.AppNotifications.Category.missedCall",
                                          actions: [ action(.callBack) ],
                                          intentIdentifiers: [],
                                          options: [])
        }
    }

    static func action(_ type: Action) -> UNNotificationAction {
        switch type {
        case .callBack:
            return UNNotificationAction(identifier: "org.whispersystems.signal.AppNotifications.Action.callBack",
                                        title: Strings.Calls.callBackButtonTitle,
                                        options: .authenticationRequired)
        }
    }
}

@available(iOS 10.0, *)
class UserNotificationsAdaptee: NSObject, OWSCallNotificationsAdaptee, UNUserNotificationCenterDelegate {
    let TAG = "[UserNotificationsAdaptee]"

    private let center: UNUserNotificationCenter

    var previewType: NotificationType {
        return Environment.getCurrent().preferences.notificationPreviewType()
    }

    override init() {
        self.center = UNUserNotificationCenter.current()
        super.init()

        center.delegate = self

        // FIXME TODO only do this after user has registered.
        // maybe the PushManager needs a reference to the NotificationsAdapter.
        requestAuthorization()

        center.setNotificationCategories(AppNotifications.allCategories)
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.badge, .sound, .alert]) { (granted, error) in
            if granted {
                Logger.debug("\(self.TAG) \(#function) succeeded.")
            } else if error != nil {
                Logger.error("\(self.TAG) \(#function) failed with error: \(error!)")
            } else {
                Logger.error("\(self.TAG) \(#function) failed without error.")
            }
        }
    }

    // MARK: - OWSCallNotificationsAdaptee

    public func presentIncomingCall(_ call: SignalCall, callerName: String) {
        Logger.debug("\(TAG) \(#function) is no-op, because it's handled with callkit.")
        // TODO since CallKit doesn't currently work on the simulator,
        // we could implement UNNotifications for simulator testing.
    }

    public func presentMissedCall(_ call: SignalCall, callerName: String) {
        Logger.debug("\(TAG) \(#function)")

        let content = UNMutableNotificationContent()
        // TODO group by thread identifier
        // content.threadIdentifier = threadId

        let notificationBody = { () -> String in
            switch previewType {
            case .noNameNoPreview:
                return Strings.Calls.missedCallNotificationBody
            case .nameNoPreview, .namePreview:
                let format = Strings.Calls.missedCallNotificationBodyWithCallerName
                return String(format: format, callerName)
        }}()

        content.body = notificationBody
        content.sound = UNNotificationSound.default()
        content.categoryIdentifier = AppNotifications.category(.missedCall).identifier

        let request = UNNotificationRequest.init(identifier: call.localId.uuidString, content: content, trigger: nil)

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


