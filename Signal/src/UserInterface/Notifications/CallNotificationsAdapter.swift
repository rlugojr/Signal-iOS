//  Created by Michael Kirk on 12/28/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation

@objc(OWSCallNotificationsAdapter)
class CallNotificationsAdapter: NSObject {

    let adaptee: OWSCallNotificationsAdaptee

    override init() {
        if #available(iOS 10.0, *) {
            adaptee = UserNotificationsAdaptee()
        } else {
            adaptee = NotificationsManager()
        }
    }

    func presentIncomingCall(fromSignalId signalId: String, callerName: String) {
        adaptee.presentIncomingCall(fromSignalId: signalId, callerName: callerName)
    }
}
